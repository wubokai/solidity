// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IOracle.sol";

contract OracleRouterMock is IOracle {
    mapping(address => uint256) public directPrices;
    mapping(address => address) public delegatedOracle;

    function setDirectPrice(address token, uint256 px) external {
        directPrices[token] = px;
    }

    function setDelegatedOracle(address token, address oracle_) external {
        delegatedOracle[token] = oracle_;
    }

    function price(address token) external view returns (uint256) {
        address sub = delegatedOracle[token];
        if (sub != address(0)) {
            return IOracle(sub).price(token);
        }
        return directPrices[token];
    }
}