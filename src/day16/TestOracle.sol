// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Match your MiniLendingMC_BadDebt dependency: IOracle.price(token)->1e18 USD price
interface IOracle {
    function price(address token) external view returns (uint256);
}

/// @notice Simple settable oracle for tests
contract TestOracle is IOracle {
    mapping(address => uint256) public prices; // 1e18 USD price per 1 token (18 decimals token assumed)

    function setPrice(address token, uint256 p1e18) external {
        prices[token] = p1e18;
    }

    function price(address token) external view returns (uint256) {
        return prices[token];
    }
}
