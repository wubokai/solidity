// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract MockOracle {
    mapping(address => uint256) public price; // 1e18 USD price

    function setPrice(address token, uint256 pE18) external {
        price[token] = pE18;
    }
}
