// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ShareVault} from "../../src/day5/ShareVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Handler} from "./Handler.sol";

contract ShareVaultInvariantTest is Test {
    MockERC20 asset;
    ShareVault vault;
    Handler handler;

    address treasury = address(0x777);

    function setUp() public {
        asset = new MockERC20("MockUSD", "mUSD", 18);
        vault = new ShareVault(asset, "ShareVault Share", "SV", treasury, 30);

        handler = new Handler(vault, asset, treasury);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = Handler.deposit.selector;
        selectors[1] = Handler.mint.selector;
        selectors[2] = Handler.withdraw.selector;
        selectors[3] = Handler.redeem.selector;
        selectors[4] = Handler.transferShares.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalAssets_matches_balance() public view {
        assertEq(vault.totalAssets(), asset.balanceOf(address(vault)), "totalAssets mismatch");
    }

    function invariant_totalSupply_equals_sumUserShares() public view {
        assertEq(vault.totalSupply(), handler.sumUserShares(), "supply != sum shares");
    }

    function invariant_conservation_of_assets() public view {
        uint256 usersAssets = handler.sumUserAssets();
        uint256 vaultAssets = asset.balanceOf(address(vault));
        uint256 treasuryAssets = asset.balanceOf(treasury);
        uint256 expected = 3 * 1_000_000e18;
        assertEq(usersAssets + vaultAssets + treasuryAssets, expected, "asset conservation broken");
    }

    function invariant_no_overclaim() public view {
        uint256 claim = vault.convertToAssets(vault.totalSupply());
        assertLe(claim, vault.totalAssets(), "over-claim");
    }
}