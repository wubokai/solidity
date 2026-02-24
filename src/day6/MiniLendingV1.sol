// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {IOracle} from "./IOracle.sol";

/// @notice Single-asset pool + single collateral token.
/// Depositors earn interest (interest increases totalDeposits).
contract MiniLendingV1 is ReentrancyGuard {
    using SafeTransferLib for ERC20;

    error ZeroAccount();
    error InsufficientLiquidity();
    error NotSolvent();
    error NotLiquidatable();
    error RepayTooSmall();
    error CollateralTooSmall();

    // token
    ERC20 public immutable asset;
    ERC20 public immutable collateral;
    IOracle public immutable oracle;

    //risk
    uint256 public immutable ltvBps;
    uint256 public immutable liqThresholdBps;
    uint256 public immutable liqBonusBps;

    //interest
    uint256 public immutable baseRateRay;
    uint256 public immutable slopeRay;

    //accounting
    uint256 public totalDeposits;
    uint256 public totalDebt;
    uint256 public totalDebtShares;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtSharesOf;

    uint256 public lastAccrue;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 shares);
    event Repay(address indexed user, uint256 amount, uint256 sharesBurned);
    event Accrue(uint256 dt, uint256 interest, uint256 newTotalDebt);
    event Liquidate(address indexed user, address indexed liquidator, uint256 repayAmount, uint256 seizedCollateral);

    constructor(

        ERC20 _asset,
        ERC20 _collateral,
        IOracle _oracle,
        uint256 _ltvBps,
        uint256 _liqThresholdBps,
        uint256 _liqBonusBps,
        uint256 _baseRateRay,
        uint256 _slopeRay
    ) {
        asset = _asset;
        collateral = _collateral;
        oracle = _oracle;
        ltvBps = _ltvBps;
        liqThresholdBps = _liqThresholdBps;
        liqBonusBps = _liqBonusBps;
        baseRateRay = _baseRateRay;
        slopeRay = _slopeRay;
        lastAccrue = block.timestamp;
    }


    function deposit(uint256 amount) external nonReentrant {
        if(amount == 0) revert ZeroAccount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        totalDeposits += amount;
        emit Deposit(msg.sender, amount);
    }
    function withdraw(uint256 amount) external nonReentrant{
        if(amount == 0) revert ZeroAccount();
        accrueInterest();
        uint256 liquid = _availableLiquidity();
        if(amount > liquid) revert InsufficientLiquidity();
        totalDeposits -= amount;
        asset.safeTransfer(msg.sender, amount);
        emit Withdraw(msg.sender, amount);

    }

    function depositCollateral(uint256 amount) external nonReentrant {
        if(amount == 0) revert ZeroAccount();
        collateral.safeTransferFrom(msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);

    }

    function withdrawCollateral(uint256 amount) external nonReentrant{
        if(amount == 0 ) revert ZeroAccount();
        accrueInterest();
        
        uint256 bal = collateralOf[msg.sender];
        if(amount > bal) revert InsufficientLiquidity();
        collateralOf[msg.sender] = bal - amount;
        if(!_isSolvent(msg.sender)) revert NotSolvent();
        
        collateral.safeTransfer(msg.sender, amount);

    }

    function borrow(uint256 amount) external nonReentrant{
        if(amount == 0) revert ZeroAccount();
        accrueInterest();

        if(amount > _availableLiquidity()) revert InsufficientLiquidity();
        uint256 shares = _debtSharesForBorrow(amount);
        totalDebtShares += shares;
        debtSharesOf[msg.sender] += shares;

        totalDebt += amount;

        if(!_isSolvent(msg.sender)) revert NotSolvent();

        asset.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount, shares);

    }

    function repay(uint256 amount) external nonReentrant returns(uint256 sharesBurned){
        if(amount == 0) revert ZeroAccount();
        accrueInterest();
    
        uint256 userShares = debtSharesOf[msg.sender];
        if(userShares == 0) revert RepayTooSmall();
        uint256 burn = _debtSharesForRepay(amount);
        if(burn == 0) revert RepayTooSmall();
        if(burn > userShares) burn = userShares;

        uint256 debtAmount = _debtAmountForShares(burn);
        debtSharesOf[msg.sender] = userShares - burn;
        totalDebtShares -= burn;
        totalDebt -= debtAmount;

        asset.safeTransferFrom(msg.sender, address(this), debtAmount);
        emit Repay(msg.sender, debtAmount, burn);

        return burn;
    }

    // Liquidation
    function liquidate(address user, uint256 repayAmount) external nonReentrant returns(uint256 seizedCollateral) {
        if(repayAmount == 0) revert ZeroAccount();
        accrueInterest();

        if(_healthFactor(user) >= 1e18) revert NotLiquidatable();

        uint256 userDebt = debtOf(user);
        if(repayAmount > userDebt) repayAmount = userDebt;
        uint256 burn = _debtSharesForRepay(repayAmount);
        if(burn == 0) revert RepayTooSmall();
        if(burn > debtSharesOf[user]) burn = debtSharesOf[user];

        uint256 exactRepay = _debtAmountForShares(burn);
        uint256 price = oracle.priceCollateralInAsset();
        uint256 repayWithBonus = exactRepay * (10_000 + liqBonusBps) / 10_000;
        seizedCollateral = repayWithBonus * 1e18 / price;

        uint256 colBal = collateralOf[user];
        if(seizedCollateral > colBal) seizedCollateral = colBal;

        debtSharesOf[user] -= burn;
        totalDebtShares -= burn;
        totalDebt -= exactRepay;

        collateralOf[user] -= seizedCollateral;

        asset.safeTransferFrom(msg.sender, address(this), exactRepay);

        collateral.safeTransfer(msg.sender, seizedCollateral);

        emit Liquidate(user, msg.sender, exactRepay, seizedCollateral);

    }

    function debtOf(address user) public view returns(uint256) {
        uint256 shares = debtSharesOf[user];
        if(shares == 0) return 0;
        return _debtAmountForShares(shares);
    }

    function collateralValueInAsset(address user) public view returns (uint256) {
        uint256 price = oracle.priceCollateralInAsset();
        return collateralOf[user]*price/1e18;
    }

    function maxBorrow(address user) public view returns (uint256) {
        return collateralValueInAsset(user)*ltvBps/10_000;
    }

    function _healthFactor(address user) internal view returns(uint256) {
        uint256 d = debtOf(user);
        if(d == 0) return type(uint256).max;
        uint256 cv = collateralValueInAsset(user);
        uint256 adj = cv*liqThresholdBps/10_000;
        return (adj*1e18)/d;
    }

    //interest
    function accrueInterest() public {
        uint256 t = block.timestamp;
        uint256 dt = t - lastAccrue;
        if(dt == 0) return;
        lastAccrue = t;

        if(totalDebt == 0) return;
        uint256 util = 0;
        if(totalDeposits > 0) {
            util = (totalDebt*1e18)/totalDeposits;
            if(util > 1e18) util = 1e18;
        }

        uint256 rateRay = baseRateRay + (slopeRay * util ) / 1e18;
        uint256 interest = (totalDebt * rateRay * dt) / 1e27;

        if(interest > 0) {
            totalDebt += interest;
            totalDeposits += interest;
            emit Accrue(dt, interest, totalDebt);
        }
    }


    //internal helpers
    function _availableLiquidity() public view returns(uint256) {
        if(totalDeposits <= totalDebt) return 0;
        return totalDeposits - totalDebt;
    }



    function _isSolvent(address user) internal view returns(bool) {
        return debtOf(user) <= maxBorrow(user);
    }

    function _debtSharesForBorrow(uint256 amount) internal view returns(uint256) {
        if( totalDebtShares == 0 || totalDebt == 0) {
            return amount;
        } 

        uint256 num = amount * totalDebtShares;

        return (num + totalDebt - 1 ) / totalDebt;

    }

    function _debtSharesForRepay(uint256 amount) internal view returns(uint256) {
        if(totalDebtShares == 0 || totalDebt == 0) {
            return amount;
        }
        return ( amount * totalDebtShares ) / totalDebt;
    }

    function _debtAmountForShares(uint256 shares) internal view returns(uint256) {
        if(totalDebtShares == 0) return 0;
        return (shares * totalDebt) / totalDebtShares;
    }

}