// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";

contract OracleMock is IOracle {
    mapping(address => uint256) public prices; // 1e18

    function setPrice(address token, uint256 p) external {
        prices[token] = p;
    }

    function price(address token) external view returns (uint256) {
        uint256 p = prices[token];
        require(p != 0, "NO_PRICE");
        return p;
    }
}