// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IOracle {
    /// @notice price of 1 collateral token in asset, scaled by 1e18
    function priceCollateralInAsset() external view returns (uint256);
}

library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    // ceilDiv for uint256
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == 0) return 0;
        return (a - 1) / b + 1;
    }
}

contract MiniLending{
    using Math for uint256;

    IERC20Like public immutable asset;
    IOracle public immutable oracle;
    IERC20Like public immutable collateral;

    uint256 public ratePerSecond;
    uint256 public lastAccrue;

    uint256 public borrowIndex;
    uint256 public totalBorrowShares;
    mapping(address => uint256) public borrowShares;

    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    uint256 public reservesBps;
    uint256 public reserves;

    mapping(address => uint256) public collateralOf;
    uint256 public constant BPS = 10_000;
    uint256 public ltvBps;
    uint256 public liqThresshouldBps;
    uint256 public liqBonusBps;
    uint256 public closeFactorBps;

    error ZeroAmount();
    error IsufficientCash();
    error IsufficientRepayAllowance();
    error BadReservesBps();
    error BadRiskParams();
    error NotSolvent();
    error NotLiquidatable();
    error RepayTooSmall();
    error CollateralTooSmall();
    error ZeroPrice();


    event Accrue(uint256 dt, uint256 oldIndex, uint256 newIndex, uint256 interest, uint256 reservesAdded);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 sharesMinted);
    event Repay(address indexed payer, address indexed user, uint256 amount, uint256 sharesBurned);
    event DepositCollateral(address indexed user, uint256 amount);
    event WithdrawCollateral(address indexed user, uint256 amount);
    event Liquidate(
        address indexed borrower,
        address indexed liquidator,
        uint256 repayUsed,
        uint256 sharesBurned,
        uint256 seizedCollateral
    );


    constructor(

        IERC20Like _asset,
        IERC20Like _collateral,
        IOracle _oracle,
        uint256 _ratePerSecond,
        uint256 _ltvBps,
        uint256 _liqThresholdBps,
        uint256 _liqBonusBps,
        uint256 _closeFactorBps

    ) {
        asset = _asset;
        ratePerSecond = _ratePerSecond;
        borrowIndex = 1e18;
        lastAccrue = block.timestamp;
        collateral = _collateral;
        oracle = _oracle;
        _setRiskParams(_ltvBps, _liqThresholdBps, _liqBonusBps, _closeFactorBps);

    }

    function cash() public view returns(uint256) {
        return asset.balanceOf(address(this));
    }

    function totalDebt() public view returns(uint256) {
        if(totalBorrowShares == 0) return 0;
        return totalBorrowShares * borrowIndex / 1e18;
    }

    function debtOf(address user) public view returns(uint256) {
        uint256 shares = borrowShares[user];
        if(shares == 0) return 0;
        return shares * borrowIndex / 1e18;
    }

    function collateralValueInAsset(address user) public view returns(uint256) {
        uint256 price = oracle.priceCollateralInAsset();
        if(price == 0) revert ZeroPrice();
        return ( collateralOf[user] * price )/ 1e18;
    }

    function maxBorrow(address user) public view returns(uint256) {
        uint256 cv = collateralValueInAsset(user);
        return (cv * ltvBps) / BPS;
    }

    function healthFactor(address user) public view returns(uint256) {
        uint256 d = debtOf(user);
        if(d == 0) return type(uint256).max;
        uint256 cv = collateralValueInAsset(user);
        uint256 adj = (cv*liqThresshouldBps) / BPS;
        return (adj * 1e18) / d;

    }

    function setRatePerSecond(uint256 newRate) external {
        accrueInterest();
        ratePerSecond = newRate;
    }

    function setReservesBps(uint256 bps) external {
        if(bps > 10_000) revert BadReservesBps();
        reservesBps = bps;
    }

    function setRiskParams(
        uint256 _ltvBps,
        uint256 _liqThresholdBps,
        uint256 _liqBonusBps,
        uint256 _closeFactorBps
    ) external {
        _setRiskParams(_ltvBps, _liqThresholdBps, _liqBonusBps, _closeFactorBps);
    }

    function _setRiskParams(
        uint256 _ltvBps,
        uint256 _liqThresholdBps,
        uint256 _liqBonusBps,
        uint256 _closeFactorBps
    ) internal {

        if(_ltvBps == 0 || _ltvBps > BPS) revert BadRiskParams();
        if(_liqThresholdBps == 0 || _liqThresholdBps > BPS) revert BadRiskParams();
        if (_ltvBps > _liqThresholdBps) revert BadRiskParams();
        if (_closeFactorBps == 0 || _closeFactorBps > BPS) revert BadRiskParams();
        if (_liqBonusBps > 20_000) revert BadRiskParams();

        ltvBps = _ltvBps;
        liqThresshouldBps = _liqThresholdBps;
        liqBonusBps = _liqBonusBps;
        closeFactorBps = _closeFactorBps;

    }


    function accrueInterest() public {
        uint256 t = block.timestamp;
        uint256 dt = t - lastAccrue;
        if(dt == 0) return;

        lastAccrue = t;
        uint256 oldIndex = borrowIndex;

        uint256 interestFactor = 1e18 + ratePerSecond * dt;
        uint256 newIndex = (oldIndex* interestFactor) / 1e18;

        borrowIndex = newIndex;
        uint256 debtOld = (totalBorrowShares * oldIndex) / 1e18;
        uint256 debtNew = (totalBorrowShares * newIndex) / 1e18;
        uint256 interest = debtNew > debtOld ? (debtNew - debtOld) : 0;

        uint256 reservesAdded = 0;
        if(interest != 0 && reservesBps != 0) {
            reservesAdded = (interest * reservesBps) / 10_000;
            reserves += reservesAdded;
        }

        emit Accrue(dt, oldIndex, newIndex, interest, reservesAdded);

    }

    function deposit(uint256 amount) external {
        if(amount == 0) revert ZeroAmount();
        require(asset.transferFrom(msg.sender, address(this), amount), "TRANSFER_FROM_FAILED");
        deposits[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposit(msg.sender, amount);
    }

    function depositCollateral(uint256 amount) external {
        if(amount == 0) revert ZeroAmount();
        require(collateral.transferFrom(msg.sender, address(this), amount)," TRANSFER_FROM_FAILED");
        collateralOf[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external {
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 bal = collateralOf[msg.sender];
        if(amount> bal) revert CollateralTooSmall();
        collateralOf[msg.sender] = bal - amount;

        if(!_isSolvent(msg.sender)) {
                revert NotSolvent();
        }

        require(collateral.transfer(msg.sender, amount), "TRANSFER_FAILED");
        emit WithdrawCollateral(msg.sender, amount);

    }

    function withdraw(uint256 amount) external {
        
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        require(deposits[msg.sender] >= amount, "INSUFFICIENT_DEPOSIT");
        if(cash() < amount) revert IsufficientCash();

        unchecked {
            deposits[msg.sender] -= amount;
            totalDeposits -= amount;
        }

        require(asset.transfer(msg.sender, amount), "TRANSFER_FAILED");
        emit Withdraw(msg.sender, amount);

    }

    function borrow(uint256 amount) external{
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        if(cash() < amount) revert IsufficientCash();

        uint256 shares = (amount * 1e18).divUp(borrowIndex);
        require(shares != 0, "ZERO_SHARES");
        borrowShares[msg.sender] += shares;
        totalBorrowShares += shares;

        require(asset.transfer(msg.sender, amount), "TRANSFER_FAILED");
        emit Borrow(msg.sender, amount, shares);

    }

    function repay(uint256 amount) external returns (uint256 repaid) {
        repaid = repayFor(msg.sender, msg.sender, amount);
    }

    function repayFor(address user, uint256 amount) external returns (uint256 repaid) {
        repaid = repayFor(msg.sender, user, amount);
    }

    function repayFor(address payer, address user, uint256 amount) public returns (uint256 repaid) {

        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 userDebt = debtOf(user);
        repaid = Math.min(amount, userDebt);

        if(repaid == 0) return 0;
        uint256 sharesToBurn = (repaid * 1e18) / borrowIndex;
        
        if(sharesToBurn == 0 ) sharesToBurn = 1;
        uint256 s = borrowShares[user];
        if(sharesToBurn > s) sharesToBurn = s;

        borrowShares[user] = s - sharesToBurn;
        totalBorrowShares -= sharesToBurn;

        require(asset.transferFrom(payer, address(this), repaid), "TRANSFER_FROM_FAILED");
        emit Repay(payer, user, repaid, sharesToBurn);

    }

    function liquidate(address borrower, uint256 repayAmount) external 
    returns (uint256 repayUsed, uint256 sharesBurned, uint256 seizedCollateral){
        if(repayAmount == 0) revert ZeroAmount();
        accrueInterest();

        if(healthFactor(borrower) >= 1e18) revert NotLiquidatable();
        uint256 userDebt = debtOf(borrower);
        if(userDebt == 0) revert NotLiquidatable();
        
        uint256 maxClose = (userDebt * closeFactorBps) / BPS;
        if(maxClose == 0) maxClose = userDebt;
        repayUsed = repayAmount;
        if(repayUsed > maxClose) repayUsed = maxClose;
        if(repayUsed > userDebt) repayUsed = userDebt;

        uint256 s = borrowShares[borrower];
        if(s == 0) revert NotLiquidatable();

        uint256 burn = (repayUsed * 1e18) / borrowIndex;
        if(burn == 0) revert RepayTooSmall();
        if(burn > s) burn = s;

        uint256 exactRepay = (burn * borrowIndex) / 1e18;
        if(exactRepay == 0) revert RepayTooSmall();

        uint256 price = oracle.priceCollateralInAsset();
        if(price == 0) revert ZeroPrice();

        uint256 repayWithBonus = (exactRepay * (BPS + liqBonusBps)) / BPS;
        seizedCollateral = (repayWithBonus * 1e18) / price;

        uint256 colBal = collateralOf[borrower];

        if(seizedCollateral > colBal) {
            seizedCollateral = colBal;
            uint256 maxRepayWithBonus = (seizedCollateral * price) / 1e18;
            uint256 maxExactRepay = (maxRepayWithBonus * BPS) / (BPS + liqBonusBps);
            if(maxExactRepay == 0) revert CollateralTooSmall();
            burn = (maxExactRepay * 1e18) / borrowIndex;
            if(burn == 0) burn =1;
            if(burn > s) burn = s;

            exactRepay = (burn * borrowIndex) / 1e18;
            if(exactRepay == 0) revert RepayTooSmall();

            repayUsed = exactRepay;

        }

        borrowShares[borrower] = s - burn;
        totalBorrowShares -= burn;
        sharesBurned = burn;

        collateralOf[borrower] = colBal - seizedCollateral;

        require(asset.transferFrom(msg.sender, address(this), repayUsed), "TRANSFER_FROM_FAILED");
        require(collateral.transfer(msg.sender, seizedCollateral), "TRANSFER_FAILED");

        emit Liquidate(borrower, msg.sender, repayUsed, burn, seizedCollateral);

    }

    function _isSolvent(address user) internal view returns(bool) {
        return debtOf(user) <= maxBorrow(user);
    }






}