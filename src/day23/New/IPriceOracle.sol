// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPriceOracle {
    /// @notice returns price in 1e18 precision
    /// semantic: 1 asset = price quote units
    function getPrice(address asset) external view returns (uint256);
}

