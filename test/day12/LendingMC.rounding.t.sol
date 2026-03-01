// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {MiniLendingMC_BadDebt} from "../../src/day12/MiniLendingMC_BadDebt.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";

contract LendingMCRoundingUnit is Test {
    MiniLendingMC_BadDebt pool;
    MockERC20 asset;
    MockERC20 col;
    MockOracle oracle;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    function setUp() external {
        asset = new MockERC20("Asset", "AST", 18);
        col   = new MockERC20("Col", "COL", 18);
        oracle = new MockOracle();

        oracle.setPrice(address(asset), 1e18);
        oracle.setPrice(address(col),  1e18);

        pool = new MiniLendingMC_BadDebt(address(asset), address(oracle), 1e12, 0.1e18);
        pool.listCollateral(address(col), true);

        // liquidity
        asset.mint(lp, 1e24);
        vm.startPrank(lp);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(1e24);
        vm.stopPrank();

        // borrower
        col.mint(alice, 1e21);
        vm.startPrank(alice);
        col.approve(address(pool), type(uint256).max);
        pool.depositCollateral(address(col), 1e21);
        pool.borrow(1e18); // small borrow
        vm.stopPrank();

    }

    function test_repay_tiny_amount_burns_zero_shares_no_revert() external {
        asset.mint(alice, 1);
        vm.startPrank(alice);
        asset.approve(address(pool), type(uint256).max);
        uint256 sharesBefore = pool.debtSharesOf(alice);
        pool.repay(1);
        uint256 sharesAfter = pool.debtSharesOf(alice);
        assertEq(sharesAfter,sharesBefore);
        vm.stopPrank();

    }

    function test_accrue_dt0_no_change() external {
        uint256 idxBefore = pool.borrowIndex();
        pool.accrueInterest();
        uint256 idxAfter = pool.borrowIndex();

        vm.warp(block.timestamp);
        idxBefore = pool.borrowIndex();
        pool.accrueInterest();
        idxAfter = pool.borrowIndex();
        assertEq(idxAfter, idxBefore);

    }

    function test_large_dt_no_overflow() external {
        vm.warp(block.timestamp + 365 days);
        pool.accrueInterest();
        assertGt(pool.borrowIndex(), 0);
    }


}