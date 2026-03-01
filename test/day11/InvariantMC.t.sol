// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {MiniLendingMC_BadDebt} from "../../src/day11/MiniLendingMC_BadDebt.sol";
import {OracleMock} from "../../src/day11/OracleMock.sol";
import {ERC20Mock} from "../../src/day11/ERC20Mock.sol";
import {HandlerMC} from "./HandlerMC.sol";

contract InvariantMC is StdInvariant, Test {

    MiniLendingMC_BadDebt pool;
    OracleMock oracle;

    ERC20Mock asset;
    ERC20Mock colA;
    ERC20Mock colB;

    HandlerMC handler;
    address[] users;

    function setUp() public {
        asset = new ERC20Mock("USD", "USD", 18);
        colA  = new ERC20Mock("CA", "CA", 18);
        colB  = new ERC20Mock("CB", "CB", 18);

        oracle = new OracleMock();
        oracle.setPrice(address(asset), 1e18);
        oracle.setPrice(address(colA),  2000e18);
        oracle.setPrice(address(colB),  1000e18);

        pool = new MiniLendingMC_BadDebt(address(asset), address(oracle), 1e12, 0.1e18); // light interest
        pool.listCollateral(address(colA), true);
        pool.listCollateral(address(colB), true);

        // create users
        users.push(address(0xA1));
        users.push(address(0xB2));
        users.push(address(0xC3));
        users.push(address(0xD4));

        // seed liquidity: make pool not trivially illiquid
        asset.mint(users[0], 500_000e18);
        vm.startPrank(users[0]);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(300_000e18);
        vm.stopPrank();

        handler = new HandlerMC(pool, oracle, asset, colA, colB, users);

        // target
        targetContract(address(handler));

        // select actions
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = HandlerMC.act_deposit.selector;
        selectors[1] = HandlerMC.act_withdraw.selector;
        selectors[2] = HandlerMC.act_depositCollateral.selector;
        selectors[3] = HandlerMC.act_withdrawCollateral.selector;
        selectors[4] = HandlerMC.act_borrow.selector;
        selectors[5] = HandlerMC.act_repay.selector;
        selectors[6] = HandlerMC.act_setPrice.selector;
        selectors[7] = HandlerMC.act_liquidate.selector;
        selectors[8] = HandlerMC.act_warp.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    }

    function invariant_borrowIndex_monotonic() public view {
        // StdInvariant runs multiple calls; we just assert >= 1e18 and no underflow.
        assertGe(pool.borrowIndex(), 1e18);
    }

    function invariant_accounting_sanity() public view {
        uint256 lhs = pool.cash() + pool.totalDebt() + pool.reserves() + pool.badDebt();
        uint256 rhs = pool.totalDeposits();
        assertGe(lhs, rhs);
    }

    function invariant_healthFactor_defined() public view {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 hf = pool.healthFactor(users[i]);
            // if debt is 0, hf should be max
            if (pool.debtOf(users[i]) == 0) {
                assertEq(hf, type(uint256).max);
            }
        }
    }



}
