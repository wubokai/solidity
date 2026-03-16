// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPriceOracle} from "./IPriceOracle.sol";

contract FixedPriceOracle is IPriceOracle {
    error UnsupportedAsset();

    address public immutable asset;
    uint256 public immutable price; // 1e18

    constructor(address _asset, uint256 _price) {
        asset = _asset;
        price = _price;
    }

    function getPrice(address a) external view override returns (uint256) {
        if (a != asset) revert UnsupportedAsset();
        return price;
    }
}