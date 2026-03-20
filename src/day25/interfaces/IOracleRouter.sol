// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleRouter {
    /// @notice returns price in 1e18 precision
    function getPrice(address asset) external view returns (uint256);
}