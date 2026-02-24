// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    function priceCollateralInAsset() external view returns (uint256);
}
