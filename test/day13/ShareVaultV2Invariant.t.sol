// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";
import "../day12/MockERC20.sol";
import "../../src/day13/ShareVaultV2.sol";
import "./ShareVaultV2Handler.sol";

contract ShareVaultV2Invariant is StdInvariant, Test {
    MockERC20 asset;
    ShareVaultV2 vault;
    ShareVaultV2Handler handler;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0x11);
    address dave  = address(0x22);

    function setUp() external{

        asset = new MockERC20("Mock USD", "mUSD", 18);
        vault = new ShareVaultV2(IERC20(address(asset)), "ShareVaultV2", "sv2");

        address [] memory users = new address[](5);
        users[0] = alice; users[1] = bob; users[2] = carol; users[3] = dave;

        handler = new ShareVaultV2Handler(asset, vault, users);

        // target handler selectors
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.mintShares.selector;
        selectors[2] = handler.withdraw.selector;
        selectors[3] = handler.redeem.selector;
        selectors[4] = handler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    }

    function invariant_totalAssets_matches_balance() external view {
        assertEq(vault.totalAssets(), asset.balanceOf(address(vault)));
    }

    function invariant_convert_monotonicity() external view {
        uint256 s1 = 1e18;
        uint256 s2 = 2e18;
        uint256 a1 = vault.convertToAssets(s1);
        uint256 a2 = vault.convertToAssets(s2);
        uint256 sh1 = vault.convertToShares(s1);
        uint256 sh2 = vault.convertToShares(s2);

        assertLe(a1, a2);
        assertLe(sh1, sh2);
    }
}
