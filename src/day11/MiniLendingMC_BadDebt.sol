// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";

/// @notice Minimal multi-collateral lending pool (single borrow asset) with
/// borrowShares+borrowIndex, close factor liquidation, backsolve, and badDebt.
contract MiniLendingMC_BadDebt is ReentrancyGuard{

    error NotListed();
    error ZeroAmount();
    error InsufficientCash();
    error NotHealthy();
    error Healthy();
    error BadDebtNotAllowed(); // optional if you want to gate
    error NoDebt();
    error NoCollateral();

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    event DepositCollateral(address indexed user, address indexed token, uint256 amount);
    event WithdrawCollateral(address indexed user, address indexed token, uint256 amount);

    event Borrow(address indexed user, uint256 amount, uint256 shares);
    event Repay(address indexed user, uint256 amount, uint256 sharesBurned);

    event Accrue(uint256 dt, uint256 newIndex, uint256 interestAccrued, uint256 reservesAdded);
    event Liquidate(
        address indexed borrower,
        address indexed liquidator,
        address indexed collateralToken,
        uint256 repayAmount,
        uint256 seizedCollateral,
        uint256 badDebtAdded
    );


    uint256 public constant WAD = 1e18;
    uint256 public constant LIQ_THRESHOLD = 0.80e18; // 80%
    uint256 public constant LIQ_BONUS     = 0.05e18; // 5%
    uint256 public constant CLOSE_FACTOR  = 0.50e18; // 50%

    uint256 public ratePerSecond;       // 1e18
    uint256 public reserveFactor;       // 1e18 (e.g. 0.1e18 => 10% interest to reserves)
    uint256 public lastAccrual;

    address public immutable asset; // single borrow/deposit asset
    IOracle  public immutable oracle;

    mapping(address => bool) public isCollateralListed;
    address[] public collateralList; 

    mapping(address => uint256) public depositOf; // asset amount deposited
    uint256 public totalDeposits;

    mapping(address => uint256) public debtSharesOf;
    uint256 public totalDebtShares;
    uint256 public borrowIndex = WAD; 

    uint256 public reserves; // asset units
    uint256 public badDebt;

    mapping(address => mapping(address => uint256)) public collateralOf;

    constructor(
        address _asset, address _oracle, uint256 _ratePerSecond, uint256 _reserveFactor
    ){
        asset = _asset;
        oracle = IOracle(_oracle);
        ratePerSecond = _ratePerSecond;
        reserveFactor = _reserveFactor;
    }

    function listCollateral(address token, bool list) external {
        isCollateralListed[token] = list;
        if (list) collateralList.push(token);
    }

    function setRate(uint256 newRate) external {
        ratePerSecond = newRate;
    } 

    function _balanceOf(address token, address who) internal view returns(uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok && data.length >= 32, "CALL_FAIL");
        return abi.decode(data, (uint256));

    }

    function _transferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAIL");
        
    }

    function _transfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory daya) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok && (daya.length == 0 || abi.decode(daya, (bool))), "TRANSFER_FAIL");
    
    }

    function _mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }

    function _mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if(x == 0 || y == 0) return 0;
        return  (x * y + ( d - 1 )) / d;
    }

    function cash() public view returns (uint256) {
        return _balanceOf(asset, address(this));
    }

    function totalDebt() public view returns (uint256) {
        return _mulDivDown(totalDebtShares, borrowIndex, WAD);
    }

    function debtOf(address user) public view returns (uint256) {
        return _mulDivDown(debtSharesOf[user], borrowIndex, WAD);
    }

    function accrueInterest() public {
        uint256 t = block.timestamp;
        uint256 dt = t - lastAccrual;
        if(dt == 0) return;
        uint256 oldIndex = borrowIndex;
        uint256 growth = _mulDivDown(ratePerSecond, dt * WAD, WAD);
        uint256 newIndex = _mulDivDown(oldIndex, WAD + growth, WAD);
        uint256 interestAccrued = _mulDivDown(totalDebtShares, (newIndex - oldIndex), WAD);
        uint256 reservesAdded = _mulDivDown(interestAccrued, reserveFactor, WAD);
        reserves += reservesAdded;
        borrowIndex = newIndex;
        lastAccrual = t;

        emit Accrue(dt, newIndex, interestAccrued, reservesAdded);

    }

    function collateralValueUSD(address user) public view returns (uint256 usdValue) {
        uint256 n = collateralList.length;
        for(uint256 i = 0; i < n; i++){
            address token = collateralList[i];
            if(!isCollateralListed[token]) continue;
            uint256 amt = collateralOf[user][token];
            if(amt == 0) continue;
            uint256 p = oracle.price(token);
            usdValue += _mulDivDown(amt, p, WAD); 
        }
    }

    function debtValueUSD(address user) public view returns (uint256) {
        uint256 d = debtOf(user);
        if(d == 0) return 0;
        uint256 p = oracle.price(asset);
        return _mulDivDown(d, p, WAD);
    }

    function healthFactor(address user) public view returns (uint256) {
        uint256 dv = debtValueUSD(user);
        if(dv == 0) return type(uint256).max;
        uint256 cv = collateralValueUSD(user);
        uint256 x = _mulDivDown(cv, LIQ_THRESHOLD, WAD);
        return _mulDivDown(x,WAD,dv);
    }

    function _requireHealthy(address user) internal view {
        if(healthFactor(user) < WAD) revert NotHealthy();
    }

    function deposit(uint256 amount) external nonReentrant {
        if(amount == 0) revert ZeroAmount();
        accrueInterest();
        _transferFrom(asset, msg.sender, address(this), amount);
        depositOf[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant {
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 bal = depositOf[msg.sender];
        require(bal >= amount, "BAL");
        if(cash() < amount) revert InsufficientCash();
        depositOf[msg.sender] = bal - amount;
        totalDeposits -= amount;

        _transfer(asset, msg.sender, amount);
        emit Withdraw(msg.sender, amount);

    }


    function depositCollateral(address token, uint256 amount) external {
        
        if(!isCollateralListed[token]) revert NotListed();
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        _transferFrom(token, msg.sender, address(this), amount);
        collateralOf[msg.sender][token] += amount;

        emit DepositCollateral(msg.sender, token, amount);
    }

    function withdrawCollateral(address token, uint256 amount) external {

        if (!isCollateralListed[token]) revert NotListed();
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 bal = collateralOf[msg.sender][token];
        require(bal >= amount, "BAL");

        collateralOf[msg.sender][token] = bal - amount;
        _requireHealthy(msg.sender);

        _transfer(token, msg.sender, amount);
        emit WithdrawCollateral(msg.sender, token, amount);

    }

    function borrow(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();

        if (cash() < amount) revert InsufficientCash();

        uint256 shares = _mulDivUp(amount, WAD, borrowIndex);
        require(shares != 0, "ZERO_SHARES");

        debtSharesOf[msg.sender] += shares;
        totalDebtShares += shares;

        _requireHealthy(msg.sender);
        _transfer(asset, msg.sender, amount);
        emit Borrow(msg.sender, amount, shares);

    }


    function repay(uint256 amount) external {
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 userShares = debtSharesOf[msg.sender];
        if(userShares == 0) revert NoDebt();

        _transferFrom(asset, msg.sender, address(this), amount);
        uint256 sharesToBurn = _mulDivDown(amount, WAD, borrowIndex);
        if(sharesToBurn == 0){
            emit Repay(msg.sender, amount, 0);
            return;
        }

        if(sharesToBurn > userShares) sharesToBurn = userShares;
        debtSharesOf[msg.sender] = userShares - sharesToBurn;
        totalDebtShares -= sharesToBurn;

        emit Repay(msg.sender, amount, sharesToBurn);

    }


    function liquidate(address borrower, address collateralToken, uint256 repayAmount) external {

        if (!isCollateralListed[collateralToken]) revert NotListed();
        if(repayAmount == 0) revert ZeroAmount();
        accrueInterest();

        if(healthFactor(borrower) >= WAD) revert Healthy();
        uint256 borrowerDebt = debtOf(borrower);
        if(borrowerDebt == 0) revert NoDebt();

        uint256 maxRepay = _mulDivDown(borrowerDebt, CLOSE_FACTOR, WAD);
        if(repayAmount > maxRepay) repayAmount = maxRepay;

        uint256 colBal = collateralOf[borrower][collateralToken];
        if(colBal == 0) revert NoCollateral();

        (uint256 actualRepay, uint256 actualSeize) =
            _computeRepayAndSeize(repayAmount, colBal, collateralToken);

        if(actualRepay != 0) {
            _transferFrom(asset, msg.sender, address(this), actualRepay);
        }

        _burnDebtShares(borrower, actualRepay);

        collateralOf[borrower][collateralToken] = colBal - actualSeize;
        _transfer(collateralToken, msg.sender, actualSeize);
        uint256 badAdded = _absorbBadDebtIfNoCollateral(borrower);

        emit Liquidate(borrower, msg.sender, collateralToken, actualRepay, actualSeize, badAdded);

    }

    function _computeRepayAndSeize(uint256 repayAmount, uint256 colBal, address collateralToken)
        internal
        view
        returns (uint256 actualRepay, uint256 actualSeize)
    {
        uint256 pAsset = oracle.price(asset);
        uint256 pCol = oracle.price(collateralToken);
        uint256 repayUSD = _mulDivDown(repayAmount, pAsset, WAD);
        uint256 seizeUSD = _mulDivDown(repayUSD, (WAD + LIQ_BONUS), WAD);

        actualRepay = repayAmount;
        actualSeize = _mulDivDown(seizeUSD, WAD, pCol);

        if(actualSeize > colBal){
            actualSeize = colBal;
            uint256 actualSeizedUSD = _mulDivDown(actualSeize, pCol, WAD);
            uint256 backRepayUSD = _mulDivDown(actualSeizedUSD, WAD, (WAD + LIQ_BONUS));
            actualRepay = _mulDivDown(backRepayUSD, WAD, pAsset);
        }
    }

    function _burnDebtShares(address borrower, uint256 repayAmount) internal {
        uint256 sharesToBurn = _mulDivDown(repayAmount, WAD, borrowIndex);
        uint256 borrowShares = debtSharesOf[borrower];
        if(sharesToBurn > borrowShares) sharesToBurn = borrowShares;

        debtSharesOf[borrower] = borrowShares - sharesToBurn;
        totalDebtShares -= sharesToBurn;
    }

    function _absorbBadDebtIfNoCollateral(address borrower) internal returns (uint256 badAdded) {
        if(collateralValueUSD(borrower) == 0){
            uint256 remainingDebt = debtOf(borrower);
            if(remainingDebt != 0){
               uint256 remShares = debtSharesOf[borrower];
               debtSharesOf[borrower] = 0;
               totalDebtShares -= remShares;

               badDebt += remainingDebt;
               badAdded = remainingDebt;
            }
        }
    }















}
