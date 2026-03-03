// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {ShareVaultV2Strategy} from "../../src/day14/ShareVaultV2Strategy.sol";
import {MockStrategy} from "../../src/day14/MockStrategy.sol";
import {MockERC20} from "./MockERC20.sol";


interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}


contract StrategyV0Test is Test {

    MockERC20 token;
    ShareVaultV2Strategy vault;
    MockStrategy strat;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV2", "SV2");
        strat = new MockStrategy(address(token), address(vault));
        vault.setStrategy(address(strat));

        token.mint(alice, 10_000e18);
        token.mint(bob,   10_000e18);

        vm.prank(alice); token.approve(address(vault), type(uint256).max);
        vm.prank(bob);   token.approve(address(vault), type(uint256).max);
    }

    function test_totalAssets_cash_plus_strategy() external {
         vm.prank(alice);
        vault.deposit(1_000e18, alice);

        assertEq(vault.totalAssets(), 1_000e18);
        assertEq(token.balanceOf(address(vault)), 1_000e18);
        assertEq(token.balanceOf(address(strat)), 0);

        vault.invest(600e18);
        assertEq(token.balanceOf(address(vault)), 400e18);
        assertEq(token.balanceOf(address(strat)), 600e18);
        assertEq(vault.totalAssets(), 1_000e18);

    }

    function test_withdraw_auto_pulls_from_strategy_when_cash_insufficient() external {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        vault.invest(900e18);
        assertEq(token.balanceOf(address(vault)), 100e18);

        vm.prank(alice);
        vault.withdraw(500e18, alice, alice);

        assertEq(token.balanceOf(alice), 10_000e18 - 1_000e18 + 500e18);
        // totalAssets reduced by 500
        assertEq(vault.totalAssets(), 500e18);
    }

    function test_profit_in_strategy_increases_totalAssets() external {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        vault.invest(1_000e18);

        // profit: mint to this test and donate to strategy
        token.mint(address(this), 100e18);
        token.transfer(address(strat), 100e18);

        assertEq(vault.totalAssets(), 1_100e18);
        // share price went up: redeem all shares should return > 1000 (roughly, with virtual)
        uint256 shares = vault.balanceOf(alice);
        uint256 assetsOut = vault.previewRedeem(shares);
        assertGt(assetsOut, 1_000e18);
    }

    function test_loss_in_strategy_decreases_totalAssets() external {
        vm.prank(alice);
        vault.deposit(1_000e18, alice);

        vault.invest(1_000e18);

        // loss: strategy sends away 200
        vm.prank(address(this));
        strat.simulateLoss(address(0xdead), 200e18);

        assertEq(vault.totalAssets(), 800e18);
    }

    function test_invest_zero_or_no_strategy_safe() external {
        vault.setStrategy(address(0));
        uint256 deployed = vault.invest(100e18);
        assertEq(deployed, 0);
    }


}