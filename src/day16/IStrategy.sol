// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IStrategy {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);

    /// @notice Vault pushes funds to strategy, then calls deposit(assets)
    function deposit(uint256 assets) external returns (uint256);

    /// @notice Strategy sends up to `assets` back to `to`
    function withdraw(uint256 assets, address to) external returns (uint256);

    function harvest() external;
}