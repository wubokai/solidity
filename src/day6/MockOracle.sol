// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IOracle} from "./IOracle.sol";

contract MockOracle is IOracle{
    uint256 public price;

    constructor(uint256 _price) {
        price = _price;
    }

    function setPrice(uint256 number) external {
        price = number;
    }

    function priceCollateralInAsset() external view override returns (uint256){
        return price;
    }

}

