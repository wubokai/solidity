// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);

    function balanceOf(address user) external view returns (uint256);
}

interface IOracleRouterLike {
    function getPrice(address asset) external view returns (uint256);
}

contract MiniLendingMC_BadDebt_TWAP_Day27 {
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;

    uint256 public constant MAX_RESERVE_FACTOR = 1e18;
    uint256 public constant MAX_CLOSE_FACTOR = 1e18;
    uint256 public constant MIN_LIQUIDATION_BONUS = 1e18;
    uint256 public constant MAX_LIQUIDATION_BONUS = 1.20e18;
    uint256 public constant MAX_RATE_PER_SECOND = 3170979198;

    IERC20Like public immutable asset;
    address public owner;
    bool public paused;

    IOracleRouterLike public oracleRouter;

    mapping(address => uint256) public depositOf;
    uint256 public totalDeposits;

    mapping(address => uint256) public debtSharesOf;
    uint256 public totalDebtShares;
    uint256 public borrowIndex;
    uint256 public ratePerSecond;
    uint256 public lastAccrualTime;
    uint256 public reserveFactorWad;
    uint256 public reserves;
    uint256 public badDebt;

    mapping(address => mapping(address => uint256)) public collateralBalanceOf;
    mapping(address => bool) public isSupportedCollateral;
    mapping(address => uint256) public collateralFactorWad;
    address[] public collateralList;

    uint256 public closeFactorWad;
    uint256 public liquidationBonusWad;

    uint256 public supplyCap;
    uint256 public borrowCap;

    uint256 private _locked = 1;

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event CollateralSupported(address indexed collateral, uint256 cfWad);
    event CollateralDeposited(
        address indexed user,
        address indexed collateral,
        uint256 amount
    );
    event CollateralWithdrawn(
        address indexed user,
        address indexed collateral,
        uint256 amount
    );
    event CollateralFactorUpdated(
        address indexed collateral,
        uint256 oldCf,
        uint256 newCf
    );
    event Borrow(address indexed user, uint256 amount, uint256 sharesMinted);
    event Repay(
        address indexed payer,
        address indexed user,
        uint256 amount,
        uint256 sharesBurned
    );
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateral,
        uint256 repayAmount,
        uint256 seizeAmount
    );
    event BadDebtRealized(address indexed user, uint256 amount);

    event OracleRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );
    event ReserveFactorUpdated(uint256 oldValue, uint256 newValue);
    event RatePerSecondUpdated(uint256 oldValue, uint256 newValue);
    event CloseFactorUpdated(uint256 oldValue, uint256 newValue);
    event LiquidationBonusUpdated(uint256 oldValue, uint256 newValue);
    event SupplyCapUpdated(uint256 oldValue, uint256 newValue);
    event BorrowCapUpdated(uint256 oldValue, uint256 newValue);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error NotOwner();
    error PausedErr();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidFactor();
    error InvalidConfig();
    error AlreadySupported();
    error UnsupportedCollateral();
    error Insolvent();
    error Healthy();
    error NoDebt();
    error BorrowCapExceeded();
    error SupplyCapExceeded();
    error InsufficientCash();
    error InsufficientDeposit();
    error InsufficientCollateral();
    error InvalidOracleRouter();
    error TransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedErr();
        _;
    }

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANT");
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(
        address _asset,
        address _oracleRouter,
        uint256 _ratePerSecond,
        uint256 _reserveFactorWad,
        uint256 _closeFactorWad,
        uint256 _liquidationBonusWad,
        uint256 _supplyCap,
        uint256 _borrowCap
    ) {
        if (_asset == address(0)) revert ZeroAddress();
        if (_oracleRouter == address(0)) revert InvalidOracleRouter();

        _validateRate(_ratePerSecond);
        _validateReserveFactor(_reserveFactorWad);
        _validateCloseFactor(_closeFactorWad);
        _validateLiquidationBonus(_liquidationBonusWad);
        _validateCap(_supplyCap);
        _validateCap(_borrowCap);

        asset = IERC20Like(_asset);
        oracleRouter = IOracleRouterLike(_oracleRouter);
        owner = msg.sender;

        ratePerSecond = _ratePerSecond;
        reserveFactorWad = _reserveFactorWad;
        closeFactorWad = _closeFactorWad;
        liquidationBonusWad = _liquidationBonusWad;
        supplyCap = _supplyCap;
        borrowCap = _borrowCap;

        borrowIndex = WAD;
        lastAccrualTime = block.timestamp;
    }

    function mulWadDown(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * y) / WAD;
    }

    function divWadDown(uint256 x, uint256 y) public pure returns (uint256) {
        return (x * WAD) / y;
    }

    function divUp(uint256 x, uint256 y) public pure returns (uint256) {
        return x == 0 ? 0 : (x - 1) / y + 1;
    }

    function pause() external onlyOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function supportedCollateral(
        address collateral,
        uint256 cfWad
    ) external onlyOwner {
        _supportCollateral(collateral, cfWad);
    }

    function supportCollateral(
        address collateral,
        uint256 cfWad
    ) external onlyOwner {
        _supportCollateral(collateral, cfWad);
    }

    function setCollateralFactor(
        address collateral,
        uint256 cfWad
    ) external onlyOwner {
        if (collateral == address(0)) revert ZeroAddress();
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        _validateCollateralFactor(cfWad);

        uint256 oldCf = collateralFactorWad[collateral];
        collateralFactorWad[collateral] = cfWad;

        emit CollateralFactorUpdated(collateral, oldCf, cfWad);
    }

    function setOracleRouter(address router) external onlyOwner {
        if (router == address(0)) revert InvalidOracleRouter();

        address oldRouter = address(oracleRouter);
        oracleRouter = IOracleRouterLike(router);

        emit OracleRouterUpdated(oldRouter, router);
    }

    function setRatePerSecond(uint256 value) external onlyOwner {
        accrueInterest();
        _validateRate(value);

        uint256 old = ratePerSecond;
        ratePerSecond = value;

        emit RatePerSecondUpdated(old, value);
    }

    function setReserveFactor(uint256 value) external onlyOwner {
        accrueInterest();
        _validateReserveFactor(value);

        uint256 old = reserveFactorWad;
        reserveFactorWad = value;

        emit ReserveFactorUpdated(old, value);
    }

    function setCloseFactor(uint256 newValue) external onlyOwner {
        _validateCloseFactor(newValue);

        uint256 old = closeFactorWad;
        closeFactorWad = newValue;

        emit CloseFactorUpdated(old, newValue);
    }

    function setLiquidationBonus(uint256 newValue) external onlyOwner {
        _validateLiquidationBonus(newValue);

        uint256 old = liquidationBonusWad;
        liquidationBonusWad = newValue;

        emit LiquidationBonusUpdated(old, newValue);
    }

    function setSupplyCap(uint256 newValue) external onlyOwner {
        _validateCap(newValue);

        uint256 old = supplyCap;
        supplyCap = newValue;

        emit SupplyCapUpdated(old, newValue);
    }

    function setBorrowCap(uint256 newValue) external onlyOwner {
        _validateCap(newValue);

        uint256 old = borrowCap;
        borrowCap = newValue;

        emit BorrowCapUpdated(old, newValue);
    }

    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    function totalDebt() public view returns (uint256) {
        return _toDebtAmountDown(totalDebtShares, currentBorrowIndex());
    }

    function debtOf(address user) public view returns (uint256) {
        return _toDebtAmountDown(debtSharesOf[user], currentBorrowIndex());
    }

    function currentBorrowIndex() public view returns (uint256) {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return borrowIndex;

        uint256 factor = WAD + (ratePerSecond * dt);
        return mulWadDown(borrowIndex, factor);
    }

    function collateralValue(address user) public view returns (uint256 value) {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            address collateral = collateralList[i];
            uint256 amount = collateralBalanceOf[user][collateral];
            if (amount == 0) continue;

            value += mulWadDown(amount, _getPrice(collateral));
        }
    }

    function borrowableCollateralValue(
        address user
    ) public view returns (uint256 value) {
        uint256 len = collateralList.length;
        for (uint256 i; i < len; ++i) {
            address collateral = collateralList[i];
            uint256 amount = collateralBalanceOf[user][collateral];
            if (amount == 0) continue;

            uint256 grossValue = mulWadDown(amount, _getPrice(collateral));
            value += mulWadDown(grossValue, collateralFactorWad[collateral]);
        }
    }

    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;

        uint256 debtValue = mulWadDown(debt, _getPrice(address(asset)));
        uint256 borrowableValue = borrowableCollateralValue(user);

        return divWadDown(borrowableValue, debtValue);
    }

    function maxBorrowable(address user) public view returns (uint256) {
        return divWadDown(
            borrowableCollateralValue(user),
            _getPrice(address(asset))
        );
    }

    function accrueInterest() public {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return;

        uint256 oldIndex = borrowIndex;
        uint256 newIndex = currentBorrowIndex();

        borrowIndex = newIndex;
        lastAccrualTime = block.timestamp;

        if (totalDebtShares == 0) return;

        uint256 oldDebt = _toDebtAmountDown(totalDebtShares, oldIndex);
        uint256 newDebt = _toDebtAmountDown(totalDebtShares, newIndex);

        if (newDebt > oldDebt) {
            uint256 interest = newDebt - oldDebt;
            reserves += mulWadDown(interest, reserveFactorWad);
        }
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        uint256 newTotal = totalDeposits + amount;
        if (newTotal > supplyCap) revert SupplyCapExceeded();

        _safeTransferFrom(address(asset), msg.sender, address(this), amount);

        depositOf[msg.sender] += amount;
        totalDeposits = newTotal;

        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (depositOf[msg.sender] < amount) revert InsufficientDeposit();
        if (_cash() < amount) revert InsufficientCash();

        depositOf[msg.sender] -= amount;
        totalDeposits -= amount;

        _safeTransfer(address(asset), msg.sender, amount);

        emit Withdraw(msg.sender, amount);
    }

    function depositCollateral(
        address collateral,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (amount == 0) revert ZeroAmount();

        _safeTransferFrom(collateral, msg.sender, address(this), amount);
        collateralBalanceOf[msg.sender][collateral] += amount;

        emit CollateralDeposited(msg.sender, collateral, amount);
    }

    function withdrawCollateral(
        address collateral,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (amount == 0) revert ZeroAmount();

        uint256 balance = collateralBalanceOf[msg.sender][collateral];
        if (balance < amount) revert InsufficientCollateral();

        accrueInterest();

        collateralBalanceOf[msg.sender][collateral] = balance - amount;
        if (healthFactor(msg.sender) < WAD) {
            collateralBalanceOf[msg.sender][collateral] = balance;
            revert Insolvent();
        }

        _safeTransfer(collateral, msg.sender, amount);

        emit CollateralWithdrawn(msg.sender, collateral, amount);
    }

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        accrueInterest();

        if (totalDebt() + amount > borrowCap) revert BorrowCapExceeded();
        if (_cash() < amount) revert InsufficientCash();

        uint256 shares = _toDebtSharesUp(amount, borrowIndex);
        if (shares == 0) revert ZeroAmount();

        debtSharesOf[msg.sender] += shares;
        totalDebtShares += shares;

        if (healthFactor(msg.sender) < WAD) {
            debtSharesOf[msg.sender] -= shares;
            totalDebtShares -= shares;
            revert Insolvent();
        }

        _safeTransfer(address(asset), msg.sender, amount);

        emit Borrow(msg.sender, amount, shares);
    }

    function repay(uint256 amount) external nonReentrant {
        _repayFor(msg.sender, msg.sender, amount);
    }

    function repayFor(address user, uint256 amount) external nonReentrant {
        _repayFor(msg.sender, user, amount);
    }

    function liquidate(
        address user,
        address collateral,
        uint256 repayAmount
    ) external nonReentrant {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (repayAmount == 0) revert ZeroAmount();

        accrueInterest();

        if (healthFactor(user) >= WAD) revert Healthy();

        uint256 debt = debtOf(user);
        if (debt == 0) revert NoDebt();

        uint256 maxRepay = mulWadDown(debt, closeFactorWad);
        if (maxRepay == 0) maxRepay = debt;

        uint256 actualRepay = repayAmount > maxRepay ? maxRepay : repayAmount;
        uint256 userCollateral = collateralBalanceOf[user][collateral];
        if (userCollateral == 0) revert InsufficientCollateral();

        uint256 seizeAmount;
        (actualRepay, seizeAmount) = _quoteLiquidation(
            collateral,
            actualRepay,
            userCollateral
        );
        if (actualRepay == 0 || seizeAmount == 0) revert InvalidConfig();

        _safeTransferFrom(address(asset), msg.sender, address(this), actualRepay);

        uint256 sharesToBurn = _toDebtSharesDown(actualRepay, borrowIndex);
        if (sharesToBurn > debtSharesOf[user]) {
            sharesToBurn = debtSharesOf[user];
        }
        if (sharesToBurn == 0 && actualRepay == debt) {
            sharesToBurn = debtSharesOf[user];
            actualRepay = debt;
        }
        if (sharesToBurn == 0) revert InvalidConfig();

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        collateralBalanceOf[user][collateral] = userCollateral - seizeAmount;
        _safeTransfer(collateral, msg.sender, seizeAmount);

        emit Liquidate(msg.sender, user, collateral, actualRepay, seizeAmount);

        _realizeBadDebtIfEmpty(user);
    }

    function realizeBadDebt(address user) external nonReentrant {
        accrueInterest();

        if (debtOf(user) == 0) revert NoDebt();
        if (collateralValue(user) != 0) revert InvalidConfig();

        _realizeBadDebt(user);
    }

    function _supportCollateral(address collateral, uint256 cfWad) internal {
        if (collateral == address(0)) revert ZeroAddress();
        if (isSupportedCollateral[collateral]) revert AlreadySupported();
        _validateCollateralFactor(cfWad);

        isSupportedCollateral[collateral] = true;
        collateralFactorWad[collateral] = cfWad;
        collateralList.push(collateral);

        emit CollateralSupported(collateral, cfWad);
    }

    function _repayFor(address payer, address user, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        accrueInterest();

        uint256 debt = debtOf(user);
        if (debt == 0) revert NoDebt();

        uint256 actualAmount = amount > debt ? debt : amount;
        uint256 sharesToBurn = _toDebtSharesDown(actualAmount, borrowIndex);

        if (sharesToBurn > debtSharesOf[user]) {
            sharesToBurn = debtSharesOf[user];
        }
        if (sharesToBurn == 0 && actualAmount == debt) {
            sharesToBurn = debtSharesOf[user];
            actualAmount = debt;
        }
        if (sharesToBurn == 0) revert InvalidConfig();

        _safeTransferFrom(address(asset), payer, address(this), actualAmount);

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        emit Repay(payer, user, actualAmount, sharesToBurn);
    }

    function _quoteLiquidation(
        address collateral,
        uint256 requestedRepay,
        uint256 userCollateral
    ) internal view returns (uint256 actualRepay, uint256 seizeAmount) {
        uint256 debtPrice = _getPrice(address(asset));
        uint256 collateralPrice = _getPrice(collateral);

        actualRepay = requestedRepay;

        uint256 repayValue = mulWadDown(actualRepay, debtPrice);
        uint256 seizeValue = mulWadDown(repayValue, liquidationBonusWad);
        seizeAmount = divWadDown(seizeValue, collateralPrice);

        if (seizeAmount > userCollateral) {
            seizeAmount = userCollateral;

            uint256 cappedSeizeValue = mulWadDown(seizeAmount, collateralPrice);
            uint256 cappedRepayValue = divWadDown(
                cappedSeizeValue,
                liquidationBonusWad
            );
            actualRepay = divWadDown(cappedRepayValue, debtPrice);

            repayValue = mulWadDown(actualRepay, debtPrice);
            seizeValue = mulWadDown(repayValue, liquidationBonusWad);
            seizeAmount = divWadDown(seizeValue, collateralPrice);
            if (seizeAmount > userCollateral) {
                seizeAmount = userCollateral;
            }
        }
    }

    function _realizeBadDebtIfEmpty(address user) internal {
        if (collateralValue(user) != 0) return;
        _realizeBadDebt(user);
    }

    function _realizeBadDebt(address user) internal {
        uint256 remainingShares = debtSharesOf[user];
        if (remainingShares == 0) return;

        uint256 remainingDebt = debtOf(user);

        debtSharesOf[user] = 0;
        totalDebtShares -= remainingShares;
        badDebt += remainingDebt;

        emit BadDebtRealized(user, remainingDebt);
    }

    function _validateCollateralFactor(uint256 cfWad) internal pure {
        if (cfWad == 0 || cfWad > WAD) revert InvalidFactor();
    }

    function _validateReserveFactor(uint256 rf) internal pure {
        if (rf > MAX_RESERVE_FACTOR) revert InvalidConfig();
    }

    function _validateCloseFactor(uint256 cf) internal pure {
        if (cf == 0 || cf > MAX_CLOSE_FACTOR) revert InvalidConfig();
    }

    function _validateLiquidationBonus(uint256 lb) internal pure {
        if (lb < MIN_LIQUIDATION_BONUS || lb > MAX_LIQUIDATION_BONUS) {
            revert InvalidConfig();
        }
    }

    function _validateRate(uint256 rps) internal pure {
        if (rps > MAX_RATE_PER_SECOND) revert InvalidConfig();
    }

    function _validateCap(uint256 cap) internal pure {
        if (cap == 0) revert InvalidConfig();
    }

    function _getPrice(address token) internal view returns (uint256) {
        return oracleRouter.getPrice(token);
    }

    function _cash() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(
                IERC20Like.transferFrom.selector,
                from,
                to,
                amount
            )
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    function _toDebtAmountDown(
        uint256 shares,
        uint256 index
    ) internal pure returns (uint256) {
        return mulWadDown(shares, index);
    }

    function _toDebtSharesUp(
        uint256 amount,
        uint256 index
    ) internal pure returns (uint256) {
        return divUp(amount * WAD, index);
    }

    function _toDebtSharesDown(
        uint256 amount,
        uint256 index
    ) internal pure returns (uint256) {
        return (amount * WAD) / index;
    }
}
