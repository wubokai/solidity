// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256) external returns (bool);
    function transfer(address to, uint256) external returns (bool);
    function transferFrom(address from, address to, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract MiniLendingMC {

    error NotAuthorized();
    error TokenNotEnabled();
    error ZeroAmount();
    error InsufficientCollateral();
    error HealthFactorTooLow();
    error NotLiquidatable();
    error CloseFactorExceeded();
    error BadParam();

    event CollateralConfigured(address indexed token, bool enabled, uint256 cf, uint256 cap);
    event DepositCollateral(address indexed user, address indexed token, uint256 amount);
    event WithdrawCollateral(address indexed user, address indexed token, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 borrowShares);
    event Repay(address indexed user, uint256 amount, uint256 sharesBurned);
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address indexed collateralToken,
        uint256 repayAmount,
        uint256 sharesBurned,
        uint256 seizeAmount
    );

    struct CollateralConfig {
        bool enabled;
        uint256 collateralFactor; // 1e18, e.g. 0.8e18
        uint256 cap;              // max total collateral amount, optional (0 = no cap)
    }

    address public immutable debtAsset; // single borrow asset (stable)
    IOracle public oracle;

    address public owner;

    uint256 public minHealthFactor = 1e18;     // HF >= 1 is healthy (adjust as you like)
    uint256 public closeFactorBps = 5_000;     // 50% default
    uint256 public liquidationBonusBps = 500;  // 5% bonus

    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrue;
    uint256 public ratePerSecond; // 1e18 scaled, linear; replace with your model
    uint256 public reserves;      // optional

    uint256 public totalBorrowShares;

    mapping(address => uint256) public borrowSharesOf;
    mapping(address => CollateralConfig) public collateralConfig; // token => config
    address[] public collateralTokens; // whitelist list for valuation iteration

    mapping(address => mapping(address => uint256)) public collateralOf; // user => token => amount
    mapping(address => uint256) public totalCollateralOf; // token => total amount held for accounting (optional)

    constructor(address _debtAsset, address _oracle) {
        debtAsset = _debtAsset;
        oracle = IOracle(_oracle);
        owner = msg.sender;
        lastAccrue = block.timestamp;
    }

    modifier onlyOwner(){
        if(msg.sender != owner) revert NotAuthorized();
        _;
    }

    function setOracle(address _oracle) external onlyOwner{
        oracle = IOracle(_oracle);
    }

    function setParams(
        uint256 _minHF,
        uint256 _closeFactorBps,
        uint256 _liqBonusBps
    ) external onlyOwner {
        if(_minHF == 0 || _closeFactorBps > 10_000 || _liqBonusBps > 10_000) revert BadParam();
        minHealthFactor = _minHF;
        closeFactorBps = _closeFactorBps;
        liquidationBonusBps = _liqBonusBps;

    }

    function setRatePerSecond(uint256 _rps) external onlyOwner {
        ratePerSecond = _rps;
    }

    function configureCollateral(
        address token,
        bool enabled,
        uint256 collateralFactor,
        uint256 cap
    ) external onlyOwner {

        if(collateralConfig[token].collateralFactor == 0 && collateralConfig[token].enabled == false){
            collateralTokens.push(token);
        }

        collateralConfig[token] = CollateralConfig({
            enabled: enabled,
            collateralFactor: collateralFactor,
            cap: cap
        });

        emit CollateralConfigured(token, enabled, collateralFactor, cap);
    }

    function depositCollateral(address token, uint256 amount) external { 
        if(amount ==0 ) revert ZeroAmount();
        CollateralConfig memory config = collateralConfig[token];
        
        if(!config.enabled) revert TokenNotEnabled();

        if(config.cap !=0){
            uint256 newTotal = totalCollateralOf[token] + amount;
            if(newTotal > config.cap) revert BadParam();
        }

        collateralOf[msg.sender][token] += amount;
        totalCollateralOf[token] += amount;

        _safeTransferFrom(token, msg.sender, address(this), amount);

        emit DepositCollateral(msg.sender, token, amount);

    }

    function withdrawCollateral(address token, uint256 amount) external { 
        if(amount ==0 ) revert ZeroAmount();
        CollateralConfig memory config = collateralConfig[token];
        if(!config.enabled) revert TokenNotEnabled();

        uint256 bal = collateralOf[msg.sender][token];
        if(bal < amount) revert InsufficientCollateral();

        collateralOf[msg.sender][token] = bal - amount;
        totalCollateralOf[token] -= amount;

        if(_debtValue(msg.sender) != 0){
            if(_healthFactor(msg.sender) < minHealthFactor) {
                
                collateralOf[msg.sender][token] = bal; // revert state
                totalCollateralOf[token] += amount;
                revert HealthFactorTooLow();

            }
        }

        _safeTransfer(token, msg.sender, amount);
        emit WithdrawCollateral(msg.sender, token, amount);

    }


    function accrueInterest() public {
        uint256 dt = block.timestamp - lastAccrue;
        if(dt ==0 ) return;
        lastAccrue = block.timestamp;

        uint256 r = ratePerSecond;

        if( r != 0 ){
            uint256 factor = 1e18 + (r * dt);
            borrowIndex = (borrowIndex * factor) / 1e18;  
        }
    }

    function borrow(uint256 amount) external {
        if(amount == 0) revert ZeroAmount();
        accrueInterest();

        uint256 shares = _amountToSharesUp(amount);
        totalBorrowShares += shares;
        borrowSharesOf[msg.sender] += shares;

        if(_healthFactor(msg.sender) < minHealthFactor) {
            // revert state
            totalBorrowShares -= shares;
            borrowSharesOf[msg.sender] -= shares;
            revert HealthFactorTooLow();
        }

        _safeTransfer(debtAsset, msg.sender, amount);
        emit Borrow(msg.sender, amount, shares);

    }

    function repay(uint256 amount) external returns(uint256 sharesBurned){

        if(amount == 0) revert ZeroAmount();
        accrueInterest();
        uint256 userShares = borrowSharesOf[msg.sender];
        if(userShares == 0) return 0;

        sharesBurned = _amountToSharesDown(amount);
        uint256 actual = _sharesToAmountUp(sharesBurned);

        borrowSharesOf[msg.sender] = userShares - sharesBurned;
        totalBorrowShares -= sharesBurned;

        _safeTransferFrom(debtAsset, msg.sender, address(this), actual);
        emit Repay(msg.sender, actual, sharesBurned);

    }

    function liquidate(
        address user,
        address collateralToken,
        uint256 repayAmount
    ) external {

        if(repayAmount == 0) revert ZeroAmount();
        CollateralConfig memory config = collateralConfig[collateralToken];
        if(!config.enabled) revert TokenNotEnabled();
        accrueInterest();

        if(_healthFactor(user) >= minHealthFactor) revert NotLiquidatable();
        uint256 userDebt = debtOf(user);
        uint256 maxClose = (userDebt * closeFactorBps) / 10_000;
        if(repayAmount > maxClose) revert CloseFactorExceeded();

        uint256 sharesToBurn = _amountToSharesDown(repayAmount);
        uint256 userShares = borrowSharesOf[user];
        if(sharesToBurn > userShares) sharesToBurn = userShares;
        if(sharesToBurn == 0) revert ZeroAmount();

        uint256 actualRepay = _sharesToAmountUp(sharesToBurn);
        uint256 repayValue = _toValue(debtAsset, actualRepay);
        uint256 seizeValue = (repayValue * (10_000 + liquidationBonusBps)) / 10_000;
        uint256 seizeAmount = _fromValue(collateralToken, seizeValue);

        uint256 userCol = collateralOf[user][collateralToken];
        if(seizeAmount > userCol) {
            seizeAmount = userCol;
            uint256 seizeAllValue = _toValue(collateralToken, seizeAmount);
            uint256 neededRepayValue = (seizeAllValue * 10_000) / (10_000 + liquidationBonusBps);
            uint256 neededRepayAmount = _fromValue(debtAsset, neededRepayValue);

            sharesToBurn = _amountToSharesDown(neededRepayAmount);
            if(sharesToBurn > userShares) sharesToBurn = userShares;
            actualRepay = _sharesToAmountUp(sharesToBurn);
        }

        borrowSharesOf[user] = userShares - sharesToBurn;
        totalBorrowShares -= sharesToBurn;

        collateralOf[user][collateralToken] = userCol - seizeAmount;
        totalCollateralOf[collateralToken] -= seizeAmount;

        _safeTransferFrom(debtAsset, msg.sender, address(this), actualRepay);
        _safeTransfer(collateralToken, msg.sender, seizeAmount);

        emit Liquidate(msg.sender, user, collateralToken, actualRepay, sharesToBurn, seizeAmount);

    }

    function debtOf(address user) public view returns(uint256) {
        uint256 shares = borrowSharesOf[user];
        if(shares == 0) return 0;
        return (shares * borrowIndex) / 1e18;
    }

    function collateralTokensLength() external view returns (uint256) {
        return collateralTokens.length;
    }

    function healthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function _healthFactor(address user) internal view returns(uint256) {
        uint256 debtV = _debtValue(user);
        if(debtV == 0) return type(uint256).max;
        uint256 adj = _collateralAdjustedValue(user);
        return (adj * 1e18) / debtV;
    }

    function _debtValue(address user) internal view returns (uint256) {
        uint256 d = debtOf(user);
        if(d == 0) return 0;
        return _toValue(debtAsset, d);
    }

    function _collateralAdjustedValue(address user) internal view returns (uint256) {
        uint256 n = collateralTokens.length;
        uint256 sum =0;

        for(uint256 i=0; i<n;i++) {
            address token = collateralTokens[i];
            CollateralConfig memory config = collateralConfig[token];
            if(!config.enabled) continue;
            uint256 amt = collateralOf[user][token];
            if(amt == 0) continue;

            uint256 v = _toValue(token, amt);
            sum += (v * config.collateralFactor) / 1e18;
        }

        return sum;
    }

    function _toValue(address token, uint256 amount) internal view returns (uint256) {
        uint256 p = oracle.price(token);
        uint8 d = IERC20(token).decimals();
        return (amount * p) / (10 ** uint256(d));
    }

    function _fromValue(address token, uint256 value) internal view returns (uint256) {
        uint256 p = oracle.price(token);
        uint8 d = IERC20(token).decimals();
        return (value * (10 ** uint256(d))) / p;
    }

    function _amountToSharesUp(uint256 amount) internal view returns (uint256) {
        return _divUp(amount * 1e18, borrowIndex);
    }

    function _amountToSharesDown(uint256 amount) internal view returns (uint256) {
        return (amount * 1e18) / borrowIndex;
    }

    function _sharesToAmountUp(uint256 shares) internal view returns (uint256) {
        // amount = ceil(shares * borrowIndex / 1e18)
        return _divUp(shares * borrowIndex, 1e18);
    }

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FAIL");
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) =
            token.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        require(ok && (data.length == 0 || abi.decode(data, (bool))), "TRANSFER_FROM_FAIL");
    }

    function _divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }



}