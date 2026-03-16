// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";

contract OracleRouter is IPriceOracle {
    error NotOwner();
    error ZeroAddress();
    error OracleNotSet(address asset);

    address public owner;
    mapping(address => address) public oracleOf;

    event OwnerTransferred(address indexed oldOwner, address indexed newOwner);
    event OracleSet(address indexed asset, address indexed oracle);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor() {
        owner = msg.sender;
        emit OwnerTransferred(address(0), msg.sender);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, newOwner);
        owner = newOwner;
    }

    function setOracle(address asset, address oracle) external onlyOwner {
        if (asset == address(0) || oracle == address(0)) revert ZeroAddress();
        oracleOf[asset] = oracle;
        emit OracleSet(asset, oracle);
    }

    function getPrice(address asset) external view override returns (uint256) {
        address oracle = oracleOf[asset];
        if (oracle == address(0)) revert OracleNotSet(asset);
        return IPriceOracle(oracle).getPrice(asset);
    }
}