// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    /// @notice returns price scaled to 1e18 (e.g. USD price with 18 decimals)
    function price(address token) external view returns (uint256);
}