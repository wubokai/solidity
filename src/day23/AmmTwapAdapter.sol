// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITwapOracleLike {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function consult(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut);
}

contract AmmTwapAdapter {
    error UnsupportedAsset();

    uint256 public constant PRICE_SCALE = 1e18;

    ITwapOracleLike public immutable twapOracle;
    address public immutable baseAsset; // collateral asset, e.g. TokenA
    address public immutable quoteAsset; // debt asset / stable, e.g. Stable

    constructor(address _twapOracle, address _baseAsset, address _quoteAsset) {
        twapOracle = ITwapOracleLike(_twapOracle);
        baseAsset = _baseAsset;
        quoteAsset = _quoteAsset;
    }

    function getPrice(address asset) external view returns (uint256 price) {
        if (asset == baseAsset) {
            price = twapOracle.consult(baseAsset, PRICE_SCALE);
        } else if (asset == quoteAsset) {
            price = PRICE_SCALE;
        } else {
            revert UnsupportedAsset();
        }
    }

    function getBasePrice() external view returns (uint256) {
        return twapOracle.consult(baseAsset, PRICE_SCALE);
    }
}
