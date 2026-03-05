// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./StrategyMocks.t.sol";
import {ShareVaultV2Strategy} from "../../src/day15/ShareVaultV2Strategy.sol";

contract StrategyPullOnWithdraw is Test {
    ShareVaultV2Strategy vault;
    MockERC20 token;
    MockStrategy strategy;

    address alice = address(0xA11CE);
    address keeper = address(0xBEEF);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV", "SV");
        vault.setKeeper(keeper);

        strategy = new MockStrategy(token);
        vault.setStrategy(address(strategy));

        token.mint(alice, 1_000_000e18);
    }

    function test_withdraw_pulls_from_strategy_when_cash_short() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.invest(990e18); // leave tiny cash

        uint256 cashBefore = vault.cashAssets();
        assertLt(cashBefore, 50e18);

        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(200e18, alice, alice);

        uint256 aliceBalAfter = token.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, 200e18, "exact assets out");
        assertEq(vault.totalAssets(), vault.cashAssets() + vault.strategyAssets());
    }

    function test_withdraw_reverts_if_strategy_cant_return_enough() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.invest(1000e18); // all cash -> strategy

        // 让策略只能 partial withdraw：直接把策略余额抽干
        // (模拟策略资金不可用/被盗/锁仓)
        uint256 strategyBal = token.balanceOf(address(strategy));
        vm.prank(address(strategy));
        token.transfer(address(0xDEAD), strategyBal);
        strategy.addVirtualProfit(1_000e18);

        vm.prank(alice);
        vm.expectRevert(ShareVaultV2Strategy.InsufficientLiquidity.selector);
        vault.withdraw(1e18, alice, alice);
    }
}
