// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FixedPriceOracle {
    mapping(address => uint256) public priceOf; // 1e18-scaled USD price

    error ZeroPrice();

    function setPrice(address asset, uint256 price) external {
        priceOf[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        uint256 p = priceOf[asset];
        if (p == 0) revert ZeroPrice();
        return p;
    }
}