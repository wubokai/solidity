// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    /// @notice Returns price in USD with 1e18 precision: USD per 1 token
    function price(address token) external view returns (uint256);
}

