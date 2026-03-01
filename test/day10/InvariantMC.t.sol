// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {MiniLendingMC} from "../../src/day10/MiniLendingMC.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";
import {LendingHandlerMC} from "./LendingHandlerMC.sol";

contract InvariantMC is StdInvariant, Test {
    MiniLendingMC pool;
    MockOracle oracle;

    MockERC20 debt;
    MockERC20 colA;
    MockERC20 colB;

    LendingHandlerMC handler;

    uint256 lastIndex;

    function setUp() external {
        oracle = new MockOracle();
        debt = new MockERC20("Debt", "DEBT", 18);
        colA = new MockERC20("ColA", "COLA", 18);
        colB = new MockERC20("ColB", "COLB", 6);

        pool = new MiniLendingMC(address(debt), address(oracle));

        pool.configureCollateral(address(colA), true, 0.8e18, 0);
        pool.configureCollateral(address(colB), true, 0.7e18, 0);

        oracle.setPrice(address(debt), 1e18);
        oracle.setPrice(address(colA), 2000e18);
        oracle.setPrice(address(colB), 1e18);

        // pool liquidity
        debt.mint(address(pool), 5_000_000e18);

        // interest settings (you can fuzz this later)
        pool.setRatePerSecond(0);

        handler = new LendingHandlerMC(pool, oracle, debt, colA, colB);

        // Selectors
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.withdraw.selector;
        selectors[2] = handler.borrow.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.setPrice.selector;
        selectors[5] = handler.warp.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));

        lastIndex = pool.borrowIndex();
    }

    function invariant_borrowIndex_monotonic() external {
        uint256 idx = pool.borrowIndex();
        assertGe(idx,lastIndex);
        lastIndex = idx;
    }

    function invariant_no_unhealthy_debtors() external {
        uint256 n = handler.actorsLength();
        for (uint256 i = 0; i < n; i++) {
            address u = handler.actors(i);
            uint256 debtV = pool.debtOf(u);
            if (debtV == 0) continue;

            uint256 hf = pool.healthFactor(u);
            if (hf >= pool.minHealthFactor()) continue;

            bool hasSeizableCollateral = false;
            uint256 m = pool.collateralTokensLength();
            for (uint256 j = 0; j < m; j++) {
                address token = pool.collateralTokens(j);
                (bool enabled,,) = pool.collateralConfig(token);
                if (!enabled) continue;
                if (pool.collateralOf(u, token) > 0) {
                    hasSeizableCollateral = true;
                    break;
                }
            }

            assertTrue(hasSeizableCollateral);
        }
    }

}