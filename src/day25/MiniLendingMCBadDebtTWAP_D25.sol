// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IOracleRouter.sol";
import "./utils/PausableOwned.sol";
import "./utils/ReentrancyGuard.sol";

interface IERC20Like {
    function balanceOf(address user) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

contract MiniLendingMCBadDebtTWAP_D25 is PausableOwned, ReentrancyGuard {
    error ZeroAddress();
    error ZeroAmount();
    error UnsupportedCollateral();
    error AlreadySupported();
    error InvalidFactor();
    error InvalidBonus();
    error InvalidCloseFactor();
    error InvalidReserveFactor();
    error InvalidRate();
    error InsufficientCash();
    error InsufficientDepositBalance();
    error TransferFailed();
    error HealthFactorTooLow();
    error HealthyPosition();
    error RepayTooLarge();
    error NoDebt();
    error NothingToRealize();
    error OraclePriceZero();

    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event CollateralSupported(
        address indexed asset,
        uint256 collateralFactorWad
    );
    event CollateralFactorUpdated(
        address indexed asset,
        uint256 collateralFactorWad
    );
    event CollateralDeposited(
        address indexed user,
        address indexed asset,
        uint256 amount
    );
    event CollateralWithdrawn(
        address indexed user,
        address indexed asset,
        uint256 amount
    );
    event Borrow(
        address indexed user,
        uint256 amount,
        uint256 debtSharesMinted
    );
    event Repay(
        address indexed payer,
        address indexed user,
        uint256 amount,
        uint256 debtSharesBurned
    );

    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateralAsset,
        uint256 repayAmount,
        uint256 collateralSeized
    );

    event BadDebtRealized(address indexed user, uint256 amount);
    event InterestAccrued(
        uint256 dt,
        uint256 interest,
        uint256 reservesAdded,
        uint256 newBorrowIndex
    );

    event RatePerSecondUpdated(uint256 newRatePerSecond);
    event ReserveFactorUpdated(uint256 newReserveFactorWad);
    event CloseFactorUpdated(uint256 newCloseFactorWad);
    event LiquidationBonusUpdated(uint256 newLiquidationBonusWad);
    event OracleRouterUpdated(address indexed newRouter);

    uint256 public constant WAD = 1e18;

    // ========= Core assets =========
    IERC20Like public immutable asset; // debt asset / liquidity asset
    IOracleRouter public oracleRouter;

    // ========= Deposit accounting =========
    mapping(address => uint256) public depositBalance;
    uint256 public totalDeposits;

    // ========= Debt accounting =========
    mapping(address => uint256) public debtSharesOf;
    uint256 public totalDebtShares;
    uint256 public borrowIndex; // 1e18
    uint256 public lastAccrualTime;
    uint256 public ratePerSecond; // 1e18 scaled
    uint256 public reserveFactorWad; // 1e18 scaled
    uint256 public reserves;
    uint256 public badDebt;

    uint256 public closeFactorWad; // <= 1e18
    uint256 public liquidationBonusWad; // ex 0.05e18 = 5%

    // ========= Collateral =========
    mapping(address => bool) public isSupportedCollateral;
    mapping(address => uint256) public collateralFactorWad; // <= 1e18
    mapping(address => mapping(address => uint256)) public collateralBalanceOf;
    address[] public collateralList;

    constructor(
        address _owner,
        address _asset,
        address _oracleRouter,
        uint256 _ratePerSecond,
        uint256 _reserveFactorWad,
        uint256 _closeFactorWad,
        uint256 _liquidationBonusWad
    ) PausableOwned(_owner) {
        if (_asset == address(0) || _oracleRouter == address(0))
            revert ZeroAddress();
        if (_reserveFactorWad > WAD) revert InvalidReserveFactor();
        if (_closeFactorWad == 0 || _closeFactorWad > WAD)
            revert InvalidCloseFactor();
        if (_liquidationBonusWad > WAD) revert InvalidBonus();

        asset = IERC20Like(_asset);
        oracleRouter = IOracleRouter(_oracleRouter);

        ratePerSecond = _ratePerSecond;
        reserveFactorWad = _reserveFactorWad;
        closeFactorWad = _closeFactorWad;
        liquidationBonusWad = _liquidationBonusWad;

        borrowIndex = WAD;
        lastAccrualTime = block.timestamp;
    }

    function setOracleRouter(address newRouter) external onlyOwner {
        if (newRouter == address(0)) revert ZeroAddress();
        oracleRouter = IOracleRouter(newRouter);
        emit OracleRouterUpdated(newRouter);
    }

    function supportCollateral(
        address collateral,
        uint256 cfWad
    ) external onlyOwner {
        if (collateral == address(0)) revert ZeroAddress();
        if (cfWad == 0 || cfWad > WAD) revert InvalidFactor();
        if (isSupportedCollateral[collateral]) revert AlreadySupported();

        isSupportedCollateral[collateral] = true;
        collateralFactorWad[collateral] = cfWad;
        collateralList.push(collateral);

        emit CollateralSupported(collateral, cfWad);
    }

    function setCollateralFactor(
        address collateral,
        uint256 cfWad
    ) external onlyOwner {
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        if (cfWad == 0 || cfWad > WAD) revert InvalidFactor();
        collateralFactorWad[collateral] = cfWad;
        emit CollateralFactorUpdated(collateral, cfWad);
    }

    function setReserveFactor(uint256 newReserveFactorWad) external onlyOwner {
        if (newReserveFactorWad > WAD) revert InvalidReserveFactor();
        reserveFactorWad = newReserveFactorWad;
        emit ReserveFactorUpdated(newReserveFactorWad);
    }

    function setCloseFactor(uint256 newCloseFactorWad) external onlyOwner {
        if (newCloseFactorWad == 0 || newCloseFactorWad > WAD)
            revert InvalidCloseFactor();
        closeFactorWad = newCloseFactorWad;
        emit CloseFactorUpdated(newCloseFactorWad);
    }

    function setLiquidationBonus(uint256 newBonusWad) external onlyOwner {
        if (newBonusWad > WAD) revert InvalidBonus();
        liquidationBonusWad = newBonusWad;
        emit LiquidationBonusUpdated(newBonusWad);
    }

    function deposit(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        _safeTransferFrom(address(asset), msg.sender, address(this), amount);
        depositBalance[msg.sender] += amount;
        totalDeposits += amount;
        emit Deposit(msg.sender, amount);
    }

    function withdraw(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > depositBalance[msg.sender])
            revert InsufficientDepositBalance();
        if (_cash() < amount) revert InsufficientCash();

        depositBalance[msg.sender] -= amount;
        totalDeposits -= amount;

        _safeTransfer(address(asset), msg.sender, amount);
        emit Withdraw(msg.sender, amount);
    }

    function depositCollateral(
        address collateral,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();

        _safeTransferFrom(collateral, msg.sender, address(this), amount);
        collateralBalanceOf[msg.sender][collateral] += amount;
        emit CollateralDeposited(msg.sender, collateral, amount);
    }

    function withdrawCollateral(
        address collateral,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (!isSupportedCollateral[collateral]) revert UnsupportedCollateral();
        uint256 bal = collateralBalanceOf[msg.sender][collateral];
        if (amount > bal) revert InsufficientDepositBalance();

        collateralBalanceOf[msg.sender][collateral] -= amount;
        if (_healthFactor(msg.sender) < WAD) revert HealthFactorTooLow();
        _safeTransfer(collateral, msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, collateral, amount);
    }

    function borrow(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        accrueInterest();
        if (_cash() < amount) revert InsufficientCash();

        uint256 shares = _toDebtSharesUp(amount);
        if (shares == 0) revert ZeroAmount();

        debtSharesOf[msg.sender] += shares;
        totalDebtShares += shares;

        if (_healthFactor(msg.sender) < WAD) revert HealthFactorTooLow();

        _safeTransfer(address(asset), msg.sender, amount);
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

        if (sharesToBurn > debtSharesOf[user])
            sharesToBurn = debtSharesOf[user];

        if (sharesToBurn == 0 && actualAmount == debt) {
            sharesToBurn = debtSharesOf[user];
            actualAmount = debt;
        }

        _safeTransferFrom(address(asset), payer, address(this), actualAmount);

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;

        emit Repay(payer, user, actualAmount, sharesToBurn);
    }

    function liquidate(
        address user,
        address collateralAsset,
        uint256 requestedRepayAmount
    ) external nonReentrant {
        if (!isSupportedCollateral[collateralAsset])
            revert UnsupportedCollateral();
        if (requestedRepayAmount == 0) revert ZeroAmount();

        accrueInterest();

        if (_healthFactor(user) >= WAD) revert HealthyPosition();

        uint256 userDebt = debtOf(user);
        if (userDebt == 0) revert NoDebt();

        uint256 maxRepay = mulWadDown(userDebt, closeFactorWad);
        if (maxRepay == 0) maxRepay = userDebt;

        uint256 repayAmount = requestedRepayAmount > maxRepay
            ? maxRepay
            : requestedRepayAmount;

        uint256 collBal = collateralBalanceOf[user][collateralAsset];
        require(collBal > 0, "NO_COLLATERAL");

        uint256 debtPrice = _getPrice(address(asset));
        uint256 collPrice = _getPrice(collateralAsset);
        // max repay supported by current collateral after bonus
        uint256 maxRepayByCollateral = divWadDown(
            mulWadDown(collBal, collPrice),
            debtPrice + mulWadDown(debtPrice, liquidationBonusWad)
        );

        if (maxRepayByCollateral == 0) revert NothingToRealize();
        if (repayAmount > maxRepayByCollateral)
            repayAmount = maxRepayByCollateral;

        uint256 collateralSeize = _calcSeizeAmount(
            collateralAsset,
            repayAmount
        );
        if (collateralSeize > collBal) {
            collateralSeize = collBal;
        }

        _safeTransferFrom(
            address(asset),
            msg.sender,
            address(this),
            repayAmount
        );
        uint256 sharesToBurn = _toDebtSharesDown(repayAmount);
        if (sharesToBurn > debtSharesOf[user])
            sharesToBurn = debtSharesOf[user];
        if (sharesToBurn == 0) revert ZeroAmount();

        debtSharesOf[user] -= sharesToBurn;
        totalDebtShares -= sharesToBurn;
        collateralBalanceOf[user][collateralAsset] -= collateralSeize;
        _safeTransfer(collateralAsset, msg.sender, collateralSeize);

        emit Liquidate(
            msg.sender,
            user,
            collateralAsset,
            repayAmount,
            collateralSeize
        );
    }

    function realizeBadDebt(address user) external nonReentrant {
        accrueInterest();
        uint256 debt = debtOf(user);
        if(debt == 0) revert NoDebt();

        uint256 totalCollValue = totalCollateralValue(user);
        if (totalCollValue != 0) revert NothingToRealize();

        uint256 shares = debtSharesOf[user];
        if(shares == 0) revert NoDebt();

        debtSharesOf[user] = 0;
        totalDebtShares -= shares;
        badDebt += debt;

        emit BadDebtRealized(user, debt);

    }

    function accrueInterest() public {
        uint256 dt = block.timestamp - lastAccrualTime;
        if (dt == 0) return;

        uint256 oldDebt = totalDebt();
        if (oldDebt == 0) {
            lastAccrualTime = block.timestamp;
            return;
        }

        uint256 interest = mulWadDown(oldDebt, ratePerSecond * dt);
        uint256 reserveAdd = mulWadDown(interest, reserveFactorWad);

        reserves += reserveAdd;
        borrowIndex = borrowIndex + mulWadDown(borrowIndex, ratePerSecond * dt);
        lastAccrualTime = block.timestamp;

        emit InterestAccrued(dt, interest, reserveAdd, borrowIndex);
    }

    // ========= Views =========

    function collateralCount() external view returns (uint256) {
        return collateralList.length;
    }

    function totalDebt() public view returns (uint256) {
        return mulWadDown(totalDebtShares, borrowIndex);
    }

    function debtOf(address user) public view returns (uint256) {
        return mulWadDown(debtSharesOf[user], borrowIndex);
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        uint256 debt = debtOf(user);
        if (debt == 0) return type(uint256).max;

        uint256 debtPrice = _getPrice(address(asset));
        uint256 debtValue = mulWadDown(debt, debtPrice);
        uint256 borrowableValue = borrowableCollateralValue(user);

        return divWadDown(borrowableValue, debtValue);
    }

    function totalCollateralValue(
        address user
    ) public view returns (uint256 value) {
        uint256 count = collateralList.length;
        for (uint256 i = 0; i < count; i++) {
            uint256 amount = collateralBalanceOf[user][collateralList[i]];
            if (amount == 0) continue;

            uint256 price = _getPrice(collateralList[i]);
            uint256 raw = mulWadDown(amount, price);
            value += raw;
        }
    }

    function borrowableCollateralValue(
        address user
    ) public view returns (uint256 value) {
        uint256 count = collateralList.length;
        for (uint256 i = 0; i < count; i++) {
            uint256 amount = collateralBalanceOf[user][collateralList[i]];
            if (amount == 0) continue;

            uint256 price = _getPrice(collateralList[i]);
            uint256 raw = mulWadDown(amount, price);
            value += mulWadDown(raw, collateralFactorWad[collateralList[i]]);
        }
    }

    function _calcSeizeAmount(
        address collateralAsset,
        uint256 repayAmount
    ) internal view returns (uint256) {
        uint256 debtPrice = _getPrice(address(asset));
        uint256 collPrice = _getPrice(collateralAsset);

        uint256 repayValue = mulWadDown(repayAmount, debtPrice);
        uint256 repayValueWithBonus = repayValue +
            mulWadDown(repayValue, liquidationBonusWad);

        return divWadDown(repayValueWithBonus, collPrice);
    }

    function _toDebtSharesUp(uint256 amount) internal view returns (uint256) {
        return divWadUp(amount, borrowIndex);
    }

    function _toDebtSharesDown(uint256 amount) internal view returns (uint256) {
        return divWadDown(amount, borrowIndex);
    }

    function _cash() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _getPrice(address a) internal view returns (uint256 p) {
        p = oracleRouter.getPrice(a);
        if (p == 0) revert OraclePriceZero();
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
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
        if (!ok || (data.length != 0 && !abi.decode(data, (bool))))
            revert TransferFailed();
    }

    // ========= Math =========

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
