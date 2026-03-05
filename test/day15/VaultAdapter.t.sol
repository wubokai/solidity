// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IStrategyLike {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets) external returns (uint256);
    function withdraw(uint256 assets, address receiver) external returns (uint256 received);
}


interface IShareVaultV2StrategyLike {
    function asset() external view returns (address);

    function strategy() external view returns (address);
    function setStrategy(address s) external;
    function setKeeper(address k) external;

    function cashAssets() external view returns (uint256);
    function strategyAssets() external view returns (uint256);
    function totalAssets() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function convertToShares(uint256 assets) external view returns (uint256);
    function convertToAssets(uint256 shares) external view returns (uint256);

    function previewDeposit(uint256 assets) external view returns (uint256);
    function previewMint(uint256 shares) external view returns (uint256);
    function previewWithdraw(uint256 assets) external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);

    function maxWithdraw(address owner) external view returns (uint256);
    function maxRedeem(address owner) external view returns (uint256);

    function invest(uint256 assets) external returns (uint256 deployed);
    function withdrawFromStrategy(uint256 assets) external returns (uint256 received);

    
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function deposit(uint256 assets, address receiver, uint256 minShares) external returns (uint256 shares);

    function mint(uint256 shares, address receiver) external returns (uint256 assets);
    function mint(uint256 shares, address receiver, uint256 maxAssets) external returns (uint256 assets);

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner, uint256 maxShares) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets) external returns (uint256 assets);

    
    function balanceOf(address) external view returns (uint256);
    function allowance(address, address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract VaultAdapter is Test {

    IShareVaultV2StrategyLike public vault;
    IERC20Like public asset;

    constructor(IShareVaultV2StrategyLike v) {
        vault = v;
        asset = IERC20Like(v.asset());
    }

    function strategy() external view returns (IStrategyLike) {
        return IStrategyLike(vault.strategy());
    }

    function cash() external view returns (uint256) {
        return asset.balanceOf(address(vault));
    }

    function deposit(address user, uint256 assets_, address receiver) external returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), assets_);
        shares = vault.deposit(assets_, receiver);
        vm.stopPrank();
    }

    function depositMin(address user, uint256 assets_, address receiver, uint256 minShares) external returns (uint256 shares) {
        vm.startPrank(user);
        asset.approve(address(vault), assets_);
        shares = vault.deposit(assets_, receiver, minShares);
        vm.stopPrank();
    }

    function mint(address user, uint256 shares_, address receiver) external returns (uint256 assets_) {
        vm.startPrank(user);
        uint256 need = vault.previewMint(shares_);
        asset.approve(address(vault), need);
        assets_ = vault.mint(shares_, receiver);
        vm.stopPrank();
    }

    function withdraw(address caller, uint256 assets_, address receiver, address owner_) external returns (uint256 shares) {
        vm.startPrank(caller);
        shares = vault.withdraw(assets_, receiver, owner_);
        vm.stopPrank();
    }

    function redeem(address caller, uint256 shares_, address receiver, address owner_) external returns (uint256 assets_) {
        vm.startPrank(caller);
        assets_ = vault.redeem(shares_, receiver, owner_);
        vm.stopPrank();
    }

    function approveShares(address owner_, address spender, uint256 amount) external {
        vm.startPrank(owner_);
        vault.approve(spender, amount);
        vm.stopPrank();
    }

    // ---- keeper/owner actions ----
    function invest(address caller, uint256 assets_) external returns (uint256 deployed) {
        vm.startPrank(caller);
        deployed = vault.invest(assets_);
        vm.stopPrank();
    }

    function pull(address caller, uint256 assets_) external returns (uint256 received) {
        vm.startPrank(caller);
        received = vault.withdrawFromStrategy(assets_);
        vm.stopPrank();
    }
}
