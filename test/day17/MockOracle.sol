// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IOracle.sol";
// 如果路径不对，就改成：import {IOracle} from "src/IOracle.sol";

contract MockOracle is IOracle {
    mapping(address => uint256) public prices;

    function setPrice(address token, uint256 px) external {
        prices[token] = px;
    }

    function price(address token) external view returns (uint256) {
        return prices[token];
    }
}