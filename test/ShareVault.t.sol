// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ShareVault} from "../src/day5/ShareVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract ShareVaultTest is Test {
    MockERC20 asset;
    ShareVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address treasury = address(0x777);

    function setUp() public {
        asset = new MockERC20("MockUSD", "mUSD", 18);
        vault = new ShareVault(asset, "ShareVault Share", "SV", treasury, 30); // 0.30%

        asset.mint(alice, 1_000_000e18);
        asset.mint(bob, 1_000_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);
    }


   function test_deposit_fee_to_treasury_and_preview_matches() public {
        uint256 gross = 100e18;
        uint256 fee = (gross * vault.feeBps()) / 10_000;
        uint256 net = gross - fee;

        uint256 tBefore = asset.balanceOf(treasury);

        vm.prank(alice);
        uint256 shares = vault.deposit(gross, alice);

        assertEq(shares, vault.previewDeposit(gross), "previewDeposit mismatch");
        assertEq(asset.balanceOf(treasury), tBefore + fee, "treasury fee");
        assertEq(vault.totalAssets(), net, "totalAssets = net");
        assertEq(vault.balanceOf(alice), shares, "alice shares");
    }

    function test_roundTrip_deposit_then_redeem_loss_is_fee_plus_dust() public {
        uint256 gross = 1000e18;
        uint256 fee = (gross * vault.feeBps()) / 10_000;

        uint256 aliceBefore = asset.balanceOf(alice);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(gross, alice);
        uint256 out = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        // allow 1 wei dust for rounding
        assertGe(out, gross - fee - 1, "redeem too low");
        uint256 loss = aliceBefore - asset.balanceOf(alice);
        assertLe(loss, fee + 1, "loss too high");
    }

    function test_withdraw_burns_ceil_shares() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 assetsW = 333e18;
        uint256 need = vault.previewWithdraw(assetsW);

        vm.prank(alice);
        uint256 burned = vault.withdraw(assetsW, bob, alice);

        assertEq(burned, need, "burn != previewWithdraw");
        assertEq(asset.balanceOf(bob), 1_000_000e18 + assetsW, "bob got assets");
    }

    function test_thirdParty_withdraw_uses_allowance() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 assetsW = 100e18;
        uint256 need = vault.previewWithdraw(assetsW);

        vm.prank(alice);
        vault.approve(bob, need);

        vm.prank(bob);
        vault.withdraw(assetsW, bob, alice);

        assertEq(vault.allowance(alice, bob), 0, "allowance not spent");
        assertEq(asset.balanceOf(bob), 1_000_000e18 + assetsW, "bob got assets");
    }

    function test_mint_exact_shares_assets_ge_preview() public {
        vm.prank(alice);
        vault.deposit(1000e18, alice);

        uint256 wantShares = 123e18;
        uint256 previewAssets = vault.previewMint(wantShares);

        vm.prank(bob);
        uint256 paid = vault.mint(wantShares, bob);

        assertGe(paid, previewAssets, "paid < preview");
        assertEq(vault.balanceOf(bob), wantShares, "bob shares");
    }

    function test_redeem_preview_matches() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(500e18, alice);

        uint256 previewOut = vault.previewRedeem(shares);

        uint256 beforeBal = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.redeem(shares, alice, alice);

        assertEq(out, previewOut, "redeem != preview");
        assertEq(asset.balanceOf(alice) - beforeBal, out, "assets delta");
        assertEq(vault.balanceOf(alice), 0, "shares burned");
    }

}