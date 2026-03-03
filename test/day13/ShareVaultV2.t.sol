// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../day12/MockERC20.sol";
import "../../src/day13/ShareVaultV2.sol";

contract ShareVaultV2Test is Test {
    MockERC20 asset;
    ShareVaultV2 vault;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0x11);

    function setUp() external {
        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new ShareVaultV2(IERC20(address(asset)), "ShareVaultV2", "sv2");

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob,   1_000_000e18);
        asset.mint(carol, 1_000_000e18);

        vm.prank(alice); asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);   asset.approve(address(vault), type(uint256).max);
        vm.prank(carol); asset.approve(address(vault), type(uint256).max);
    }

    function test_deposit_then_redeem_approx_roundtrip() external {
        vm.startPrank(alice);
        uint256 assetsIn =1000e18;
        uint256 shares = vault.deposit(assetsIn,alice);
        uint256 assetsOut = vault.redeem(shares,alice,alice);
        vm.stopPrank();

        assertLe(assetsIn - assetsOut,2);

    }

    function test_mint_preview_consistency() external {
        vm.startPrank(alice);
        uint256 shares = 1234e18;
        uint256 assetsPreview = vault.previewMint(shares);
        uint256 assetsPaid = vault.mint(shares, alice);
        vm.stopPrank();

        assertEq(assetsPreview,assetsPaid);
    }

    function test_withdraw_preview_consistency() external {
        vm.startPrank(alice);
        vault.deposit(10_000e18, alice);
        uint256 assets = 777e18;
        uint256 sharesPreview = vault.previewWithdraw(assets);
        uint256 sharesBurned = vault.withdraw(assets, alice, alice);
        vm.stopPrank();

        assertEq(sharesPreview, sharesBurned);
    } 

    function test_allowance_withdraw_on_behalf() external {
        vm.prank(alice);
        vault.deposit(10_000e18, alice);
        uint256 assetsToWithdraw = 100e18;
        uint256 sharesNeeded = vault.previewWithdraw(assetsToWithdraw);
        vm.prank(alice);
        vault.approve(bob, sharesNeeded)  ;
        vm.prank(bob);
        uint256 burned = vault.withdraw(assetsToWithdraw, bob, alice);
        assertEq(burned, sharesNeeded);
    }

    function test_donation_inflation_attack_resisted() external {
        vm.prank(alice);
        uint256 s1 = vault.deposit(1e18, alice);
        uint256 donation = 1_000_000e18;
        vm.prank(bob);
        asset.transfer(address(vault), donation);
        vm.prank(alice);
        uint256 s2 = vault.deposit(1e18, alice);
        assertGt(s2, 0);
        assertLt(s2, s1);
        vm.startPrank(alice);
        uint256 assetsOut = vault.redeem(vault.balanceOf(alice), alice, alice);
        vm.stopPrank();
        assertApproxEqAbs(assetsOut, donation + 2e18, 1e6);

    }

    function test_max_functions() external {
        vm.prank(alice);
        vault.deposit(123e18,alice);
        uint256 shares = vault.balanceOf(alice);
        assertEq(vault.maxRedeem(alice), shares);
        assertEq(vault.maxWithdraw(alice), vault.convertToAssets(shares));

    }




}
