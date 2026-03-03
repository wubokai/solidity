// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Math {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (x == 0 || y == 0) return 0;
        return (x * y) / d;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        if (x == 0 || y == 0) return 0;
        return (x * y + d - 1) / d;
    }

    function divUp(uint256 x, uint256 d) internal pure returns (uint256) {
        return x == 0 ? 0 : (x + d - 1) / d;
    }
}