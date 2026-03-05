// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    function price(address token) external view returns (uint256);
}

/// @notice A router oracle: token -> oracle, else fallback set price
contract CompositeOracle is IOracle {
    mapping(address => address) public oracleOf; // token -> oracle
    mapping(address => uint256) public staticPrice; // fallback static

    function setOracle(address token, address oracle) external {
        oracleOf[token] = oracle;
    }

    function setStaticPrice(address token, uint256 p1e18) external {
        staticPrice[token] = p1e18;
    }

    function price(address token) external view returns (uint256) {
        address o = oracleOf[token];
        if (o != address(0)) return IOracle(o).price(token);
        return staticPrice[token];
    }
}