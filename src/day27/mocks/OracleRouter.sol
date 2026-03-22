// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256);
}

contract OracleRouter {
    address public owner;
    mapping(address => address) public oracleOf;

    error NotOwner();
    error ZeroAddress();
    error OracleNotSet();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setOracle(address asset, address oracle) external onlyOwner {
        if (asset == address(0) || oracle == address(0)) revert ZeroAddress();
        oracleOf[asset] = oracle;
    }

    function getPrice(address asset) external view returns (uint256) {
        address oracle = oracleOf[asset];
        if (oracle == address(0)) revert OracleNotSet();
        return IPriceOracle(oracle).getPrice(asset);
    }
}