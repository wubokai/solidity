// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
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

contract MiniLending {
    using Math for uint256;

    IERC20Like public immutable asset;
    uint256 public ratePerSecond;
    uint256 public lastAccrue;

    uint256 public borrowIndex;
    uint256 public totalBorrowShares;
    mapping(address => uint256) public borrowShares;

    uint256 public totalDeposits;
    mapping(address => uint256) public deposits;

    uint256 public reservesBps;
    uint256 public reserves;

    error ZeroAmount();
    error IsufficientCash();
    error IsufficientRepayAllowance();
    error BadReservesBps();

    event Accrue(uint256 dt, uint256 oldIndex, uint256 newIndex, uint256 interest, uint256 reservesAdded);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Borrow(address indexed user, uint256 amount, uint256 sharesMinted);
    event Repay(address indexed payer, address indexed user, uint256 amount, uint256 sharesBurned);

    constructor(IERC20Like _asset, uint256 _ratePerSecond) {
        asset = _asset;
        ratePerSecond = _ratePerSecond;
        borrowIndex = 1e18;
        lastAccrue = block.timestamp;
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

    function setRatePerSecond(uint256 newRate) external {
        accrueInterest();
        ratePerSecond = newRate;
    }

    function setReservesBps(uint256 bps) external {
        if(bps > 10_000) revert BadReservesBps();
        reservesBps = bps;
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


}