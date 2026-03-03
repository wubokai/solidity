// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../day12/MockERC20.sol";
import "../../src/day13/ShareVaultV2.sol";
import "../../src/day13/Math.sol";

contract ShareVaultV2Handler is Test {
    using Math for uint256;

    MockERC20 public asset;
    ShareVaultV2 public vault;

    address[] public users;

    // ghost accounting (best-effort)
    uint256 public ghostTotalDeposited;
    uint256 public ghostTotalWithdrawn;
    uint256 public ghostTotalDonated;

    constructor(MockERC20 _asset, ShareVaultV2 _vault, address[] memory _users) {
        asset = _asset;
        vault = _vault;
        users = _users;

        for (uint256 i; i < users.length; i++) {
            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
        }
    }

    function _u(uint256 seed) internal view returns(address) {
        return users[seed%users.length];
    }

    function deposit(uint256 seed, uint256 assets) external {
        address u = _u(seed);
        assets = bound(assets,1,10_000e18);
        asset.mint(u,assets);

        vm.prank(u);
        uint256 shares = vault.deposit(assets,u);
        require(shares > 0, "shares0");

        ghostTotalDeposited += assets;

    } 

    function mintShares(uint256 seed, uint256 shares) external {
        address u = _u(seed);
        shares = bound(shares, 1, 10_000e18);

        uint256 needAssets = vault.previewMint(shares);
        asset.mint(u, needAssets);
        vm.prank(u);
        uint256 paid = vault.mint(shares,u);
        ghostTotalDeposited += paid;

    }

    function withdraw(uint256 seed, uint256 assets) external {
        address u = _u(seed);

        uint256 maxW = vault.maxWithdraw(u);
        if (maxW == 0) return;

        assets = bound(assets,1,maxW);
        vm.prank(u);
        uint256 burned = vault.withdraw(assets, u, u);
        require(burned > 0, "burn 0");

        ghostTotalWithdrawn += assets;
    }

    function redeem(uint256 seed, uint256 shares) external {
        address u = _u(seed);
        uint256 maxR = vault.maxRedeem(u);
        if(maxR == 0) return;
        shares = bound(shares,1,maxR);

        vm.prank(u);
        uint256 assets = vault.redeem(shares, u, u);
        ghostTotalWithdrawn += assets;
    }

    function donate(uint256 seed, uint256 assets) external{
        address u =_u(seed);
        assets = bound(assets, 1, 50_000e18);
        asset.mint(u, assets);
        vm.prank(u);
        asset.transfer(address(vault), assets);
        
        ghostTotalDonated += assets;
    }

}