// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../../src/day10/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) public p; // 1e18

    function setPrice(address token, uint256 price1e18) external {
        p[token] = price1e18;
    }

    function price(address token) external view returns (uint256) {
        uint256 x = p[token];
        require(x != 0, "NO_PRICE");
        return x;
    }
}