// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./StrategyMocks.t.sol";
import {ShareVaultV2Strategy} from "../../src/day15/ShareVaultV2Strategy.sol";

contract AllowancePullPath is Test {
    ShareVaultV2Strategy vault;
    MockERC20 token;
    MockStrategy strategy;

    address alice = address(0xA11CE);
    address spender = address(0xB0B);
    address keeper = address(0xBEEF);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV", "SV");
        vault.setKeeper(keeper);

        strategy = new MockStrategy(token);
        vault.setStrategy(address(strategy));

        token.mint(alice, 1_000_000e18);
    }

    function test_spender_withdraw_triggers_pull_and_spends_allowance() external {
        // alice deposit
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        // approve spender shares
        vault.approve(spender, type(uint256).max);
        vm.stopPrank();

        // invest most to make cash insufficient
        vm.prank(keeper);
        vault.invest(990e18);

        uint256 cashBefore = vault.cashAssets();
        assertLt(cashBefore, 50e18);

        // spender withdraw on behalf of alice; should pull from strategy
        uint256 aliceBalBefore = token.balanceOf(alice);

        vm.prank(spender);
        vault.withdraw(200e18, alice, alice);

        uint256 aliceBalAfter = token.balanceOf(alice);
        assertEq(aliceBalAfter - aliceBalBefore, 200e18);
        assertEq(vault.totalAssets(), vault.cashAssets() + vault.strategyAssets());
    }
}