// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract D4MiniLending is ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error InsufficientCollateral();
    error BorrowExceedsLimit();
    error DebtTooHighAfterWithdraw();
    error ETHTransferFailed();

    IERC20 public immutable stable;

    uint256 public constant PRICE_USD_PER_ETH = 2000e18; // 1 ETH = 2000 USD
    uint256 public constant LTV_BPS = 7500; // 75% LTV
    uint256 public constant BORROW_FEE_BPS = 10;
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD =  1e18;

    mapping(address=>uint256) public collateralETH;
    mapping(address=>uint256) public debt;

    event DepositCollateral(address indexed user, uint256 ethAmount);
    event WithdrawCollateral(address indexed user, uint256 ethAmount);
    event Borrow(address indexed user, uint256 amountOut, uint256 fee, uint256 newDebt);
    event Repay(address indexed user, uint256 amountIn, uint256 newDebt);
    event Fund(address indexed from, uint256 amount);

    constructor(IERC20 _stable){
        stable = _stable;

    }

    function fund(uint256 amount) external{
        if(amount == 0) revert ZeroAmount();
        stable.safeTransferFrom(msg.sender, address(this), amount);
        emit Fund(msg.sender, amount);
    }

    function depositCollateral() external payable{
        if(msg.value == 0) revert ZeroAmount();
        collateralETH[msg.sender] += msg.value;
        emit DepositCollateral(msg.sender, msg.value);
    }

    function borrow(uint256 amount) external nonReentrant{

        if(amount == 0) revert ZeroAmount();
        uint256 fee = _mulDivDown(amount, BORROW_FEE_BPS, BPS);
        uint256 newDebt = debt[msg.sender] + amount + fee;

        uint256 maxB = maxBorrowUSD(msg.sender);
        if(newDebt > maxB) revert BorrowExceedsLimit();
        debt[msg.sender] = newDebt;
        stable.safeTransfer(msg.sender, amount);
        emit Borrow(msg.sender, amount, fee, newDebt);

    }

    function _mulDivDown(uint256 x, uint256 y, uint256 z) internal pure returns (uint256) {
        return x * y / z;
    }

    function maxBorrowUSD(address user) public view returns (uint256) {
        return _maxBorrowFromCollateral(collateralETH[user]);
    }

    function _maxBorrowFromCollateral(uint256 collateralWei) internal pure returns (uint256) {
        uint256 collateralUSD = _mulDivDown(collateralWei, PRICE_USD_PER_ETH, WAD);
        return _mulDivDown(collateralUSD, LTV_BPS, BPS);
    }

    function repay(uint256 amount) external nonReentrant{
        if(amount ==0) revert ZeroAmount();
        uint256 d = debt[msg.sender];
        if(d == 0) return;
        uint256 pay = amount > d ? d : amount;
        debt[msg.sender] = d-pay;
        stable.safeTransferFrom(msg.sender, address(this), pay);

        emit Repay(msg.sender, pay, debt[msg.sender]);

    }

    function withdrawCollateral(uint256 ethAmount) external nonReentrant {
        if(ethAmount == 0) revert ZeroAmount();
        uint256 c = collateralETH[msg.sender];
        if(ethAmount > c) revert InsufficientCollateral();
        uint256 newCollateral = c - ethAmount;
        uint256 maxB = _maxBorrowFromCollateral(newCollateral);

        if(debt[msg.sender] >maxB) revert DebtTooHighAfterWithdraw();

        collateralETH[msg.sender] = newCollateral;
        (bool ok,) = msg.sender.call{value: ethAmount}("");
        if(!ok) revert ETHTransferFailed();
        emit WithdrawCollateral(msg.sender,ethAmount);

    }


    function healthFactorBps(address user) external view returns (uint256) {
        uint256 d = debt[user];
        if(d==0) return type(uint256).max;
        uint256 maxB = maxBorrowUSD(user);
        return _mulDivDown(maxB, BPS, d);
    }

    receive() external payable{}

}
