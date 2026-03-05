// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IStrategy} from "./IStrategy.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

/// @dev Dumb strategy: just holds tokens. Vault must pre-transfer before deposit().
contract MockStrategy is IStrategy {
    IERC20Like public immutable ASSET;
    address public immutable VAULT;

    error NotVault();

    constructor(address asset_, address vault_) {
        ASSET = IERC20Like(asset_);
        VAULT = vault_;
    }

    function asset() external view returns (address) {
        return address(ASSET);
    }

    function totalAssets() public view returns (uint256) {
        return ASSET.balanceOf(address(this));
    }

    function deposit(uint256 /*assets*/) external returns (uint256) {
        if (msg.sender != VAULT) revert NotVault();
        // no-op; assets already transferred in
        return 0;
    }

    function withdraw(uint256 assets, address to) external returns (uint256 withdrawn) {
        if (msg.sender != VAULT) revert NotVault();
        uint256 bal = ASSET.balanceOf(address(this));
        withdrawn = assets > bal ? bal : assets;
        require(ASSET.transfer(to, withdrawn), "T");
    }

    function harvest() external {}

    /// @notice simulate loss by transferring tokens out
    function simulateLoss(address to, uint256 assets) external {
        require(ASSET.transfer(to, assets), "T");
    }
}