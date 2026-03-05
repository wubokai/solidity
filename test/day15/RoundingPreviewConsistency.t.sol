// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./StrategyMocks.t.sol";
import {ShareVaultV2Strategy} from "../../src/day15/ShareVaultV2Strategy.sol";

contract RoundingPreviewConsistency is Test {
    ShareVaultV2Strategy vault;
    MockERC20 token;
    MockStrategy strategy;

    address alice = address(0xA11CE);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV", "SV");
        strategy = new MockStrategy(token);
        vault.setStrategy(address(strategy));

        token.mint(alice, 1_000_000e18);
    }

    function test_previewDeposit_equals_deposit_for_small_amount() external {
        uint256 assets_ = 1; // 1 wei
        uint256 ps = vault.previewDeposit(assets_);

        vm.startPrank(alice);
        token.approve(address(vault), assets_);
        uint256 got = vault.deposit(assets_, alice);
        vm.stopPrank();

        assertEq(got, ps, "previewDeposit mismatch");
    }

    function test_previewWithdraw_matches_withdraw_shares_charge() external {
        vm.startPrank(alice);
        token.approve(address(vault), 10e18);
        vault.deposit(10e18, alice);
        vm.stopPrank();

        uint256 assets_ = 1; // tiny withdraw
        uint256 expectShares = vault.previewWithdraw(assets_);

        uint256 beforeShares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.withdraw(assets_, alice, alice);

        uint256 afterShares = vault.balanceOf(alice);
        assertEq(beforeShares - afterShares, expectShares, "withdraw share burn mismatch");
    }
}
