// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IOracleRouter.sol";

contract MockOracleRouter is IOracleRouter {
    mapping(address => uint256) public prices;

    error PriceNotSet();

    function setPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        uint256 p = prices[asset];
        if (p == 0) revert PriceNotSet();
        return p;
    }
}