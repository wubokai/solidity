// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20LikeLending {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address user) external view returns (uint256);
}

interface IPriceOracleLike {
    function getPrice(address asset) external view returns (uint256);
}

contract LendingHarness {
    error InvalidAmount();
    error TransferFailed();
    error InsufficientBorrowPower();
    error InsufficientLiquidity();

    uint256 public constant PRICE_SCALE = 1e18;
    uint256 public constant BPS = 10_000;

    IERC20LikeLending public immutable collateralToken;
    IERC20LikeLending public immutable debtToken;
    IPriceOracleLike public immutable oracle;

    // conservative params for testing
    uint256 public immutable collateralFactorBps;      // e.g. 5000 => 50%
    uint256 public immutable liquidationThresholdBps;  // e.g. 8000 => 80%

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf;

    event DepositCollateral(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount);
    event Repay(address indexed user, uint256 amount);

    constructor(
        address _collateralToken,
        address _debtToken,
        address _oracle,
        uint256 _collateralFactorBps,
        uint256 _liquidationThresholdBps
    ) {
        collateralToken = IERC20LikeLending(_collateralToken);
        debtToken = IERC20LikeLending(_debtToken);
        oracle = IPriceOracleLike(_oracle);
        collateralFactorBps = _collateralFactorBps;
        liquidationThresholdBps = _liquidationThresholdBps;
    }

    function depositCollateral(uint256 amount) external {
        if(amount == 0) revert InvalidAmount();
        _safeTransferFrom(collateralToken, msg.sender, address(this), amount);
        collateralOf[msg.sender] += amount;
        emit DepositCollateral(msg.sender, amount);

    }

    function borrow(uint256 amount) external {
        if(amount == 0) revert InvalidAmount();
        if (amount > availableBorrow(msg.sender)) revert InsufficientBorrowPower();
        if (debtToken.balanceOf(address(this)) < amount) revert InsufficientLiquidity();

        debtOf[msg.sender] += amount;
        _safeTransfer(debtToken, msg.sender, amount);
        emit Borrow(msg.sender, amount);
    }

    function repay(uint256 amount) external {
        if(amount == 0) revert InvalidAmount();
        uint256 debt = debtOf[msg.sender];
        if(amount >debt) amount = debt;
        
        _safeTransferFrom(debtToken, msg.sender, address(this), amount);
        debtOf[msg.sender] -= amount;
        emit Repay(msg.sender, amount);
    }

    function collateralValue(address user) public view returns (uint256) {
        uint256 price = oracle.getPrice(address(collateralToken)); // stable per collateral, 1e18 scaled
        return (collateralOf[user] * price) / PRICE_SCALE;
    }

    function maxBorrow(address user) public view returns (uint256) {
        return (collateralValue(user) * collateralFactorBps) / BPS;
    }

    function availableBorrow(address user) public view returns (uint256) {
        uint256 maxB = maxBorrow(user);
        uint256 debt = debtOf[user];
        if (debt >= maxB) return 0;
        return maxB - debt;
    }
    
    function healthFactor(address user) public view returns (uint256) {
        uint256 debt = debtOf[user];
        if (debt == 0) return type(uint256).max;

        uint256 adjustedCollateral = (collateralValue(user) * liquidationThresholdBps) / BPS;
        return (adjustedCollateral * PRICE_SCALE) / debt;
    }

    function isLiquidatable(address user) external view returns (bool) {
        return healthFactor(user) < PRICE_SCALE;
    }

    function _safeTransfer(IERC20LikeLending token, address to, uint256 amount) internal {
        bool ok = token.transfer(to, amount);
        if (!ok) revert TransferFailed();
    }

    function _safeTransferFrom(IERC20LikeLending token, address from, address to, uint256 amount) internal {
        bool ok = token.transferFrom(from, to, amount);
        if (!ok) revert TransferFailed();
    }

}
