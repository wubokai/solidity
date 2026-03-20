// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface IOracleRouterLike {
    function getPrice(address asset) external view returns (uint256); // 1e18
}

contract MiniLendingMC_BadDebt_TWAP {

   
    // =============================================================
    //                           CONSTANTS
    // =============================================================

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_CLOSE_FACTOR_WAD = 1e18;         // 100%
    uint256 public constant MAX_COLLATERAL_FACTOR_WAD = 0.95e18; // 95%
    uint256 public constant MAX_LIQUIDATION_BONUS_WAD = 0.20e18; // 20%
    uint256 public constant MAX_RESERVE_FACTOR_WAD = 0.50e18;    // 50%
    uint256 public constant MAX_RATE_PER_SECOND = 3170979198;     // ~10% APR in wad/sec-scale style? kept conservative
    // 这里是“线性利率模型”的每秒 rate，上限给得比较保守。你后面可按自己项目调整。

    // =============================================================
    //                             ERRORS
    // =============================================================

    error NotOwner();
    error Paused();
    error ZeroAddress();
    error ZeroAmount();
    error TransferFailed();
    error AlreadySupported();
    error UnsupportedCollateral();
    error InvalidFactor();
    error InvalidBonus();
    error InvalidCloseFactor();
    error InvalidReserveFactor();
    error InvalidRate();
    error InvalidCap();
    error Insolvent();
    error NoDebt();
    error Healthy();
    error NothingToRealize();
    error CollateralStillExists();
    error BorrowCapExceeded();
    error SupplyCapExceeded();

    // =============================================================
    //                             EVENTS
    // =============================================================

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);

    event PausedSet(bool paused);

    event OracleRouterUpdated(address indexed oldRouter, address indexed newRouter);
    event RatePerSecondUpdated(uint256 oldValue, uint256 newValue);
    event ReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event CloseFactorUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationBonusUpdated(uint256 oldValue, uint256 newValue);
    event BorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event SupplyCapUpdated(uint256 oldValue, uint256 newValue);

    event CollateralSupported(address indexed collateral, uint256 cfWad);
    event CollateralFactorUpdated(address indexed collateral, uint256 oldCfWad, uint256 newCfWad);

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);

    event DepositCollateral(address indexed user, address indexed collateral, uint256 amount);
    event WithdrawCollateral(address indexed user, address indexed collateral, uint256 amount);

    event Borrow(address indexed user, uint256 amount, uint256 sharesMinted);
    event Repay(address indexed payer, address indexed user, uint256 amount, uint256 sharesBurned);

    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateral,
        uint256 repayAmount,
        uint256 sharesBurned,
        uint256 collateralSeized
    );

    event BadDebtRealized(address indexed user, uint256 amount);

    // =============================================================
    //                         STATE: ADMIN
    // =============================================================

    address public owner;
    bool public paused;

    IERC20Like public immutable asset;
    IOracleRouterLike public router;

    // =============================================================
    //                   STATE: LENDING / INTEREST
    // =============================================================

    mapping(address => uint256) public depositBalanceOf;
    uint256 public totalDeposits;
    mapping(address => uint256) public debtSharesOf;
    uint256 public totalDebtShares;
    uint256 public borrowIndex; // 1e18
    uint256 public lastAccrualTime;
    uint256 public ratePerSecond;    // 1e18-scaled simple linear per second
    uint256 public reserveFactorWad; // 1e18-scaled
    uint256 public reserves;
    uint256 public badDebt;

    // =============================================================
    //                      STATE: RISK PARAMS
    // =============================================================

    uint256 public closeFactorWad;      // 1e18-scaled, e.g. 0.5e18
    uint256 public liquidationBonusWad; // 1e18-scaled, e.g. 0.1e18

    uint256 public borrowCap; // nominal debt cap
    uint256 public supplyCap; // pool deposit cap

    // =============================================================
    //                   STATE: MULTI COLLATERAL
    // =============================================================

    mapping(address => bool) public isSupportedCollateral;
    mapping(address => uint256) public collateralFactorWad; // collateral => cfWad
    address[] public collateralList;

    mapping(address => mapping(address => uint256)) public collateralBalanceOf; // user => collateral => amount
    mapping(address => uint256) public totalCollateralOfAsset;

    // =============================================================
    //                         REENTRANCY LOCK
    // =============================================================

    uint256 private _locked = 1;
    modifier nonReentrant() {
        require(_locked == 1, "REENTRANT");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    // =============================================================
    //                           CONSTRUCTOR
    // =============================================================

    constructor(
        address asset_,
        address router_,
        uint256 ratePerSecond_,
        uint256 reserveFactorWad_,
        uint256 closeFactorWad_,
        uint256 liquidationBonusWad_,
        uint256 borrowCap_,
        uint256 supplyCap_
    ) {
        if (asset_ == address(0) || router_ == address(0)) revert ZeroAddress();
        if (reserveFactorWad_ > MAX_RESERVE_FACTOR_WAD) revert InvalidReserveFactor();
        if (closeFactorWad_ == 0 || closeFactorWad_ > MAX_CLOSE_FACTOR_WAD) revert InvalidCloseFactor();
        if (liquidationBonusWad_ > MAX_LIQUIDATION_BONUS_WAD) revert InvalidBonus();
        if (ratePerSecond_ > MAX_RATE_PER_SECOND) revert InvalidRate();
        if (borrowCap_ == 0 || supplyCap_ == 0) revert InvalidCap();

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        asset = IERC20Like(asset_);
        router = IOracleRouterLike(router_);

        borrowIndex = WAD;
        lastAccrualTime = block.timestamp;

        ratePerSecond = ratePerSecond_;
        reserveFactorWad = reserveFactorWad_;
        closeFactorWad = closeFactorWad_;
        liquidationBonusWad = liquidationBonusWad_;
        borrowCap = borrowCap_;
        supplyCap = supplyCap_;
    }

    // =============================================================
    //                         ADMIN ACTIONS
    // =============================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setOracleRouter(address newRouter) external onlyOwner {
        if(newRouter == address(0)) revert ZeroAddress();
        address old = address(router);
        router = IOracleRouterLike(newRouter);
        emit OracleRouterUpdated(old, newRouter);

    }

    function setPaused(bool isPaused) external onlyOwner(){
        paused = isPaused;
        emit PausedSet(isPaused);
    }

    function setRatePerSecond(uint256 newRate) external onlyOwner {
        accrueInterest();
        if (newRate > MAX_RATE_PER_SECOND) revert InvalidRate();
        uint256 old = ratePerSecond;
        ratePerSecond = newRate;
        emit RatePerSecondUpdated(old, newRate);
    }

    function setReserveFactor(uint256 newReserveFactorWad) external onlyOwner {
        accrueInterest();
        if (newReserveFactorWad > MAX_RESERVE_FACTOR_WAD) revert InvalidReserveFactor();
        uint256 old = reserveFactorWad;
        reserveFactorWad = newReserveFactorWad;
        emit ReserveFactorUpdated(old, newReserveFactorWad);
    }

    function setCloseFactor(uint256 newCloseFactorWad) external onlyOwner {
        if (newCloseFactorWad == 0 || newCloseFactorWad > MAX_CLOSE_FACTOR_WAD) revert InvalidCloseFactor();
        uint256 old = closeFactorWad;
        closeFactorWad = newCloseFactorWad;
        emit CloseFactorUpdated(old, newCloseFactorWad);
    }

    function setLiquidationBonus(uint256 newLiquidationBonusWad) external onlyOwner {
        if (newLiquidationBonusWad > MAX_LIQUIDATION_BONUS_WAD) revert InvalidBonus();
        uint256 old = liquidationBonusWad;
        liquidationBonusWad = newLiquidationBonusWad;
        emit LiquidationBonusUpdated(old, newLiquidationBonusWad);
    }

    function setBorrowCap(uint256 newBorrowCap) external onlyOwner {
        if (newBorrowCap == 0) revert InvalidCap();
        uint256 old = borrowCap;
        borrowCap = newBorrowCap;
        emit BorrowCapUpdated(old, newBorrowCap);
    }

    function setSupplyCap(uint256 newSupplyCap) external onlyOwner {
        if (newSupplyCap == 0) revert InvalidCap();
        uint256 old = supplyCap;
        supplyCap = newSupplyCap;
        emit SupplyCapUpdated(old, newSupplyCap);
    }

    function supportCollateral(address collateral, uint256 cfWad) external onlyOwner {
        if (collateral == address(0)) revert ZeroAddress();
        if (isSupportedCollateral[collateral]) revert AlreadySupported();
        if (cfWad == 0 || cfWad > MAX_COLLATERAL_FACTOR_WAD) revert InvalidFactor();

        isSupportedCollateral[collateral] = true;
        collateralFactorWad[collateral] = cfWad;
        collateralList.push(collateral);

        emit CollateralSupported(collateral, cfWad);
    }

    function setCollateralFactor(address collateral, uint256 newCfWad) external onlyOwner {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (newCfWad == 0 || newCfWad > MAX_COLLATERAL_FACTOR_WAD) revert InvalidFactor();

        uint256 old = collateralFactorWad[collateral];
        collateralFactorWad[collateral] = newCfWad;

        emit CollateralFactorUpdated(collateral, old, newCfWad);
    }

    // =============================================================
    //                       USER: POOL DEPOSIT/WITHDRAW
    // =============================================================

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (totalDeposits + amount > supplyCap) revert SupplyCapExceeded();

        bool ok = asset.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        depositBalanceOf[msg.sender] += amount;
        totalDeposits += amount;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (depositBalanceOf[msg.sender] < amount) revert Insolvent();

        depositBalanceOf[msg.sender] -= amount;
        totalDeposits -= amount;

        bool ok = asset.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Withdraw(msg.sender, amount);
    }

    // =============================================================
    //                     USER: COLLATERAL MANAGEMENT
    // =============================================================

    function depositCollateral(address collateral, uint256 amount) external nonReentrant whenNotPaused {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (amount == 0) revert ZeroAmount();

        bool ok = IERC20Like(collateral).transferFrom(msg.sender, address(this), amount);
        if (!ok) revert TransferFailed();

        collateralBalanceOf[msg.sender][collateral] += amount;
        totalCollateralOfAsset[collateral] += amount;

        emit DepositCollateral(msg.sender, collateral, amount);
    }

    function withdrawCollateral(address collateral, uint256 amount) external nonReentrant whenNotPaused {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (amount == 0) revert ZeroAmount();

        uint256 bal = collateralBalanceOf[msg.sender][collateral];
        require(bal >= amount, "INSUFFICIENT_COLLATERAL");

        collateralBalanceOf[msg.sender][collateral] = bal - amount;
        totalCollateralOfAsset[collateral] -= amount;

        if (_healthFactor(msg.sender) < WAD) revert Insolvent();

        bool ok = IERC20Like(collateral).transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit WithdrawCollateral(msg.sender, collateral, amount);
    }

    // =============================================================
    //                         USER: BORROW / REPAY
    // =============================================================

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        accrueInterest();

        uint256 newDebt = totalDebt() + amount;
        if (newDebt > borrowCap) revert BorrowCapExceeded();

        uint256 shares = _toDebtSharesUp(amount);
        if (shares == 0) shares = amount; // fallback guard for tiny values

        debtSharesOf[msg.sender] += shares;
        totalDebtShares += shares;

        if (_healthFactor(msg.sender) < WAD) {
            debtSharesOf[msg.sender] -= shares;
            totalDebtShares -= shares;
            revert Insolvent();
        }

        bool ok = asset.transfer(msg.sender, amount);
        if (!ok) revert TransferFailed();

        emit Borrow(msg.sender, amount, shares);
    }

    function repay(uint256 amount) external nonReentrant {
        _repayFor(msg.sender, msg.sender, amount);
    }

    function repayFor(address user, uint256 amount) external nonReentrant {
        _repayFor(msg.sender, user, amount);
    }

    function _repayFor(address payer, address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        accrueInterest();

        uint256 debt = debtOf(user);
        if (debt == 0) revert NoDebt();

        uint256 actualAmount = amount > debt ? debt : amount;
        uint256 sharesToBurn = _toDebtSharesDown(actualAmount);

        if (sharesToBurn > debtSharesOf[user]) {
            sharesToBurn = debtSharesOf[user];
        }

        if (sharesToBurn == 0 && actualAmount == debt) {
            sharesToBurn = debtSharesOf[user];
            actualAmount = debt;
        } else if (sharesToBurn == 0) {
            revert ZeroAmount();
        }

        bool ok = asset.transferFrom(payer, address(this), actualAmount);
        if (!ok) revert TransferFailed();

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        emit Repay(payer, user, actualAmount, sharesToBurn);
    }

    // =============================================================
    //                          LIQUIDATION
    // =============================================================

    function liquidate(
        address user,
        address collateral,
        uint256 repayAmount
    ) external nonReentrant returns (uint256 actualRepay, uint256 seized) {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (repayAmount == 0) revert ZeroAmount();

        accrueInterest();

        if (_healthFactor(user) >= WAD) revert Healthy();

        uint256 debt = debtOf(user);
        if (debt == 0) revert NoDebt();

        uint256 userCollateral = collateralBalanceOf[user][collateral];
        uint256 debtPrice = _getPrice(address(asset));
        uint256 colPrice = _getPrice(collateral);

        // collateral不足时，反推实际可repay amount
        (actualRepay, seized) = _computeRepayAndSeize(
            repayAmount,
            debt,
            debtPrice,
            colPrice,
            userCollateral
        );

        if (actualRepay == 0 || seized == 0) revert ZeroAmount();

        if (!asset.transferFrom(msg.sender, address(this), actualRepay)) revert TransferFailed();

        uint256 sharesToBurn = _toDebtSharesDown(actualRepay);
        if (sharesToBurn > debtSharesOf[user]) {
            sharesToBurn = debtSharesOf[user];
        }
        if (sharesToBurn == 0) {
            // 极小值保护
            sharesToBurn = 1;
        }
        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;
        collateralBalanceOf[user][collateral] -= seized;
        totalCollateralOfAsset[collateral] -= seized;

        if (!IERC20Like(collateral).transfer(msg.sender, seized)) revert TransferFailed();

        emit Liquidate(msg.sender, user, collateral, actualRepay, sharesToBurn, seized);

    }

    function _computeRepayAndSeize(
        uint256 requestedRepay,
        uint256 debt,
        uint256 debtPrice,
        uint256 colPrice,
        uint256 userCollateral
    ) internal view returns (uint256 actualRepay, uint256 seized) {
        uint256 maxClose = mulWadDown(debt, closeFactorWad);
        if (maxClose == 0) maxClose = debt;

        actualRepay = requestedRepay > maxClose ? maxClose : requestedRepay;
        seized = _seizeFromRepay(actualRepay, debtPrice, colPrice);

        if (seized > userCollateral) {
            seized = userCollateral;
            uint256 seizedValue = mulWadDown(seized, colPrice);
            uint256 discountedRepayValue = divWadDown(
                seizedValue,
                WAD + liquidationBonusWad
            );
            actualRepay = divWadDown(discountedRepayValue, debtPrice);

            if (actualRepay > maxClose) {
                actualRepay = maxClose;
            }

            seized = _seizeFromRepay(actualRepay, debtPrice, colPrice);
            if (seized > userCollateral) seized = userCollateral;
        }
    }

    function _seizeFromRepay(
        uint256 actualRepay,
        uint256 debtPrice,
        uint256 colPrice
    ) internal view returns (uint256 seized) {
        uint256 repayValue = mulWadDown(actualRepay, debtPrice);
        uint256 seizeValue = mulWadDown(repayValue, WAD + liquidationBonusWad);
        seized = divWadDown(seizeValue, colPrice);
    }

    function realizeBadDebt(address user) external nonReentrant returns (uint256 amount) {
        accrueInterest();

        if (_hasAnyCollateral(user)) revert CollateralStillExists();

        amount = debtOf(user);
        if (amount == 0) revert NothingToRealize();

        badDebt += amount;
        totalDebtShares -= debtSharesOf[user];
        debtSharesOf[user] = 0;

        emit BadDebtRealized(user, amount);
    }

    // =============================================================
    //                           INTEREST
    // =============================================================

    function accrueInterest() public {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return;

        uint256 oldIndex = borrowIndex;

        // linear index update: newIndex = oldIndex * (1 + rate * dt)
        uint256 interestFactor = WAD + (ratePerSecond * dt);
        uint256 newIndex = mulWadDown(oldIndex, interestFactor);

        borrowIndex = newIndex;
        lastAccrualTime = block.timestamp;

        uint256 oldDebt = totalDebtByIndex(oldIndex);
        uint256 newDebt = totalDebtByIndex(newIndex);

        if (newDebt > oldDebt) {
            uint256 interestAccrued = newDebt - oldDebt;
            uint256 reserveCut = mulWadDown(interestAccrued, reserveFactorWad);
            reserves += reserveCut;
        }
    }

    // =============================================================
    //                             VIEWS
    // =============================================================

    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    function totalDebt() public view returns (uint256) {
        return totalDebtByIndex(borrowIndex);
    }

    function totalDebtByIndex(uint256 index) public view returns (uint256) {
        if (totalDebtShares == 0) return 0;
        return mulWadDown(totalDebtShares, index);
    }

    function debtOf(address user) public view returns (uint256) {
        if (debtSharesOf[user] == 0) return 0;
        return mulWadDown(debtSharesOf[user], borrowIndex);
    }

    function cash() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function collateralValue(address user) public view returns (uint256 totalValue) {
        uint256 len = collateralList.length;
        for (uint256 i = 0; i < len; ++i) {
            address c = collateralList[i];
            uint256 amount = collateralBalanceOf[user][c];
            if (amount == 0) continue;

            uint256 px = _getPrice(c);
            totalValue += mulWadDown(amount, px);
        }
    }

    function borrowableCollateralValue(address user) public view returns (uint256 totalBorrowable) {
        uint256 len = collateralList.length;
        for (uint256 i = 0; i < len; ++i) {
            address c = collateralList[i];
            uint256 amount = collateralBalanceOf[user][c];
            if (amount == 0) continue;

            uint256 px = _getPrice(c);
            uint256 value = mulWadDown(amount, px);
            totalBorrowable += mulWadDown(value, collateralFactorWad[c]);
        }
    }

    function _healthFactor(address user) internal view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;

        uint256 debtPrice = _getPrice(address(asset));
        uint256 debtValue = mulWadDown(debt, debtPrice);
        uint256 borrowableValue = borrowableCollateralValue(user);

        return divWadDown(borrowableValue, debtValue);
    }

    function _hasAnyCollateral(address user) internal view returns (bool yes) {
        uint256 len = collateralList.length;
        for (uint256 i = 0; i < len; ++i) {
            if (collateralBalanceOf[user][collateralList[i]] > 0) return true;
        }
    }

    function _getPrice(address token) internal view returns (uint256 px) {
        px = router.getPrice(token);
        require(px > 0, "ZERO_PRICE");
    }

    // =============================================================
    //                        SHARE CONVERSIONS
    // =============================================================

    function _toDebtSharesUp(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return divWadUp(amount, borrowIndex);
    }

    function _toDebtSharesDown(uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        return divWadDown(amount, borrowIndex);
    }

    // =============================================================
    //                           MATH
    // =============================================================

    function mulWadDown(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * y) / WAD;
    }

    function divWadDown(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * WAD) / y;
    }

    function divWadUp(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * WAD + y - 1) / y;
    }

}
