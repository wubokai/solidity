// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";
import {ShareVault} from "../../src/day5/ShareVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract Handler is Test {
    ShareVault public vault;
    MockERC20 public asset;
    address public treasury;

    address[] internal users;

    constructor(ShareVault _vault, MockERC20 _asset, address _treasury){
        vault = _vault;
        asset = _asset;
        treasury = _treasury;
    
        users.push(address(0xA11CE));
        users.push(address(0xB0B));
        users.push(address(0xC0C));

        for(uint256 i =0; i<users.length; i++){
            asset.mint(users[i],1_000_000e18);
            vm.prank(users[i]);
            asset.approve(address(vault), type(uint256).max);
            vm.prank(users[i]);
            asset.approve(address(this), type(uint256).max);
        }
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function deposit(uint256 seedUser, uint256 shares) external {
        address u = _user(seedUser);
        shares = bound(shares, 1e18, 1000e18);

        vm.prank(u);
        try vault.mint(shares,u){} catch{}

    }

    function mint(uint256 seedUser, uint256 shares) external {
        address u = _user(seedUser);
        shares = bound(shares, 1, 5_000e18);
        vm.prank(u);
        try vault.mint(shares, u) {} catch {}
    }

    function withdraw(uint256 seedUser, uint256 assets) external {
        address u = _user(seedUser);
        assets = bound(assets, 1, 5_000e18);
        vm.prank(u);
        try vault.withdraw(assets, u, u) {} catch {}
    }

    function redeem(uint256 seedUser, uint256 shares) external {
        address u = _user(seedUser);
        shares = bound(shares, 1, 5_000e18);
        vm.prank(u);
        try vault.redeem(shares, u, u) {} catch {}
    }

    function transferShares(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _user(fromSeed);
        address to = _user(toSeed);
        if (from == to) return;
        amount = bound(amount, 0, vault.balanceOf(from));
        if (amount == 0) return;
        vm.prank(from);
        vault.transfer(to, amount);
    }

    function sumUserShares() external view returns (uint256 s) {
        for (uint256 i = 0; i < users.length; i++) s += vault.balanceOf(users[i]);
    }

    function sumUserAssets() external view returns (uint256 a) {
        for (uint256 i = 0; i < users.length; i++) a += asset.balanceOf(users[i]);
    }



}