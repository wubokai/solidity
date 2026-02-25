// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day8/MiniLendingV1.2.sol";
import "../../src/day8/MockERC20.sol";

contract MiniLendingTest is Test {
    MockERC20 token;
    MiniLending pool;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);

        // pick a small-ish linear rate for tests: e.g. 1e12 per sec ~ 0.000001 per sec
        pool = new MiniLending(IERC20Like(address(token)), 1e12);

        // fund users and approve
        token.mint(alice, 1_000_000e18);
        token.mint(bob,   1_000_000e18);

        vm.prank(alice); token.approve(address(pool), type(uint256).max);
        vm.prank(bob);   token.approve(address(pool), type(uint256).max);

        // seed pool liquidity via deposit from alice
        vm.prank(alice);
        pool.deposit(500_000e18);
    }

    function test_accrue_monotonic() external {
        uint256 i0 = pool.borrowIndex();
        vm.warp(block.timestamp + 100);
        pool.accrueInterest();
        uint256 i1 = pool.borrowIndex();
        assertGe(i1, i0);
        assertGt(i1, i0);
    }

    function test_accrue_dt0_noChange() external {
        uint256 i0 = pool.borrowIndex();
        pool.accrueInterest(); // dt=0 likely
        uint256 i1 = pool.borrowIndex();
        assertEq(i1, i0);
    }

    function test_borrow_then_accrue_debtGrows() external {
        vm.prank(bob);
        pool.borrow(1000e18);

        uint256 d0 = pool.debtOf(bob);
        vm.warp(block.timestamp + 3600);
        pool.accrueInterest();
        uint256 d1 = pool.debtOf(bob);

        assertGt(d1, d0);
    }

    function test_repay_full_overpayEndsAtZeroish() external {
        vm.prank(bob);
        pool.borrow(1000e18);

        vm.warp(block.timestamp + 1000);
        pool.accrueInterest();

        uint256 debt = pool.debtOf(bob);
        vm.prank(bob);
        pool.repay(debt + 123e18);

        // allow tiny rounding dust; you can assert <= 1 wei or <= 1e6 depending on your design
        uint256 d2 = pool.debtOf(bob);
        assertLe(d2, 1); // if you keep it strict; otherwise relax
        assertEq(pool.borrowShares(bob), 0);
    }

    function test_repay_partial() external {
        vm.prank(bob);
        pool.borrow(1000e18);

        vm.warp(block.timestamp + 500);
        pool.accrueInterest();

        uint256 d0 = pool.debtOf(bob);

        vm.prank(bob);
        pool.repay(d0 / 3);

        uint256 d1 = pool.debtOf(bob);
        assertLt(d1, d0);
        assertGt(d1, 0);
    }

    function test_twoUsers_noUserIterationStillWorks() external {
        vm.prank(alice);
        pool.borrow(2000e18);
        vm.prank(bob);
        pool.borrow(1000e18);

        uint256 da0 = pool.debtOf(alice);
        uint256 db0 = pool.debtOf(bob);

        vm.warp(block.timestamp + 7200);
        pool.accrueInterest();

        uint256 da1 = pool.debtOf(alice);
        uint256 db1 = pool.debtOf(bob);

        assertGt(da1, da0);
        assertGt(db1, db0);
    }

    function test_totalDebt_formula_consistent() external {
        vm.prank(bob);
        pool.borrow(1000e18);

        vm.warp(block.timestamp + 1234);
        pool.accrueInterest();

        uint256 td = pool.totalDebt();
        uint256 derived = (pool.totalBorrowShares() * pool.borrowIndex()) / 1e18;

        // allow 0 diff in same formula; should equal
        assertEq(td, derived);
    }
}