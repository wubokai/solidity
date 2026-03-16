// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMiniAMMOracleSource {
    function token0() external view returns (address);
    function token1() external view returns (address);

    function currentCumulativePrices()
        external
        view
        returns (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        );
}

contract SimpleTWAPOracle {
    error InvalidToken();
    error PeriodNotElapsed();
    error ZeroPeriod();

    uint256 public constant PRICE_SCALE = 1e18;

    IMiniAMMOracleSource public immutable amm;
    address public immutable token0;
    address public immutable token1;

    uint32 public immutable period;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    // 1e18 fixed-point average prices
    // price0Average = token1 per token0
    // price1Average = token0 per token1
    uint256 public price0Average;
    uint256 public price1Average;

    event Updated(
        uint256 price0Average,
        uint256 price1Average,
        uint32 blockTimestamp
    );

    constructor(address _amm, uint32 _period) {
        if (_period == 0) revert ZeroPeriod();
        amm = IMiniAMMOracleSource(_amm);
        token0 = amm.token0();
        token1 = amm.token1();
        period = _period;

        (
            uint256 _price0CumulativeLast,
            uint256 _price1CumulativeLast,
            uint32 _blockTimestampLast
        ) = amm.currentCumulativePrices();

        price0CumulativeLast = _price0CumulativeLast;
        price1CumulativeLast = _price1CumulativeLast;
        blockTimestampLast = _blockTimestampLast;
    }

    function update() external {
        (
            uint256 price0Cumulative,
            uint256 price1Cumulative,
            uint32 blockTimestamp
        ) = amm.currentCumulativePrices();

        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed < period) revert PeriodNotElapsed();

        price0Average =
            (price0Cumulative - price0CumulativeLast) /
            uint256(timeElapsed);
        price1Average =
            (price1Cumulative - price1CumulativeLast) /
            uint256(timeElapsed);

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;

        emit Updated(price0Average, price1Average, blockTimestamp);
    }

    function consult(
        address tokenIn,
        uint256 amountIn
    ) external view returns (uint256 amountOut) {
        if (tokenIn == token0) {
            amountOut = (amountIn * price0Average) / PRICE_SCALE;
        } else if (tokenIn == token1) {
            amountOut = (amountIn * price1Average) / PRICE_SCALE;
        } else {
            revert InvalidToken();
        }
    }
}
