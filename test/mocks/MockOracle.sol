// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "../../src/day6/IOracle.sol";

contract MockOracle is IOracle {
    // price = asset per 1 collateral, scaled by 1e18
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 _price) external {
        price = _price;
    }

    function priceCollateralInAsset() external view returns (uint256) {
        return price;
    }
}
