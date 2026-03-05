// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./StrategyMocks.t.sol";
import {ShareVaultV2Strategy} from "../../src/day15/ShareVaultV2Strategy.sol";

contract StrategyProfitLoss is Test {
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

    function test_profit_mint_to_strategy_increases_totalAssets() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.invest(900e18);

        uint256 beforeTA = vault.totalAssets();

        // 更真实：直接把 token mint 到 strategy 余额（profit）
        token.mint(address(strategy), 100e18);

        uint256 afterTA = vault.totalAssets();
        assertGt(afterTA, beforeTA, "profit should increase TA");
        assertEq(afterTA, vault.cashAssets() + vault.strategyAssets());
    }

    function test_loss_bps_decreases_totalAssets_view() external {
        vm.startPrank(alice);
        token.approve(address(vault), 1000e18);
        vault.deposit(1000e18, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.invest(900e18);

        uint256 beforeTA = vault.totalAssets();

        strategy.setLossBps(1000); // 10% loss in accounting

        uint256 afterTA = vault.totalAssets();
        assertLt(afterTA, beforeTA, "loss should decrease TA");
        assertEq(afterTA, vault.cashAssets() + vault.strategyAssets());
    }
}
