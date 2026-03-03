// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IVault {
    function deposit(uint256, address) external returns (uint256);
    function withdraw(uint256, address, address) external returns (uint256);
    function invest(uint256) external returns (uint256);
    function totalAssets() external view returns (uint256);
    function cashAssets() external view returns (uint256);
    function strategyAssets() external view returns (uint256);
    function asset() external view returns (address);
}

contract StrategyV0Handler is Test {
    IVault public vault;
    IERC20 public asset;
    address public strategy;

    address[] public actors;

    uint256 public ghostDonateToVault;
    uint256 public ghostDonateToStrategy;

    constructor(address vault_, address strategy_, address[] memory actors_) {
        vault = IVault(vault_);
        asset = IERC20(vault.asset());
        strategy = strategy_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function actDeposit(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 0, 2_000e18);

        vm.startPrank(a);
        asset.approve(address(vault), type(uint256).max);
        vault.deposit(amt, a);
        vm.stopPrank();
    }

    function actWithdraw(uint256 seed, uint256 amt) external {
        address a = _actor(seed);
        amt = bound(amt, 0, 2_000e18);

        vm.startPrank(a);
        vault.withdraw(amt, a, a);
        vm.stopPrank();
    }

    function actInvest(uint256 amt) external {
        amt = bound(amt, 0, 5_000e18);
        // this contract (invariant) is likely owner/keeper if deployed that way; otherwise prank in invariant setup
        vault.invest(amt);
    }

    function actDonateToVault(uint256 amt) external {
        amt = bound(amt, 0, 500e18);
        require(asset.transfer(address(vault), amt), "T");
        ghostDonateToVault += amt;
    }

    function actDonateToStrategy(uint256 amt) external {
        amt = bound(amt, 0, 500e18);
        require(asset.transfer(strategy, amt), "T");
        ghostDonateToStrategy += amt;
    }
}