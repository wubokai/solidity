// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {MiniLendingMC_BadDebt} from "../../src/day11/MiniLendingMC_BadDebt.sol";
import {OracleMock} from "../../src/day11/OracleMock.sol";
import {ERC20Mock} from "../../src/day11/ERC20Mock.sol";

contract BadDebtTest is Test {
    
    MiniLendingMC_BadDebt pool;
    OracleMock oracle;

    ERC20Mock asset;
    ERC20Mock colA;
    ERC20Mock colB;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() public {

        asset = new ERC20Mock("USD Stable", "USD", 18);
        colA  = new ERC20Mock("CollateralA", "CA", 18);
        colB  = new ERC20Mock("CollateralB", "CB", 18);

        oracle = new OracleMock();
        oracle.setPrice(address(asset), 1e18); // $1
        oracle.setPrice(address(colA),  2000e18); // $2000
        oracle.setPrice(address(colB),  1000e18); // $1000

        // ratePerSecond/reserveFactor can be zero in unit tests to isolate liquidation logic
        pool = new MiniLendingMC_BadDebt(address(asset), address(oracle), 0, 0);

        pool.listCollateral(address(colA), true);
        pool.listCollateral(address(colB), true);

        // Mint balances
        asset.mint(alice, 1_000_000e18);
        asset.mint(bob,   1_000_000e18);
        colA.mint(alice,  100e18);
        colB.mint(alice,  100e18);

        vm.prank(alice); asset.approve(address(pool), type(uint256).max);
        vm.prank(bob);   asset.approve(address(pool), type(uint256).max);
        vm.prank(alice); colA.approve(address(pool), type(uint256).max);
        vm.prank(alice); colB.approve(address(pool), type(uint256).max);

        // provide pool liquidity via deposits
        vm.prank(bob); pool.deposit(500_000e18);

    }

    function test_liquidation_basic() public {

        vm.prank(alice);
        pool.depositCollateral(address(colA), 1e18);
        vm.prank(alice);
        pool.borrow(1000e18);
        oracle.setPrice(address(colA), 1200e18); // 1200 * 80% < 1000, now undercollateralized
        assertLt(pool.healthFactor(alice), 1e18);
        vm.prank(bob);
        pool.liquidate(alice, address(colA), 300e18);
        assertLt(pool.debtOf(alice), 1000e18);
        assertLt(pool.collateralOf(alice, address(colA)), 1e18);

    }

    function test_badDebt_when_collateral_insufficient() public {
        vm.prank(alice);
        pool.depositCollateral(address(colA), 1e18);
        vm.prank(alice);
        pool.borrow(1500e18);
        oracle.setPrice(address(colA), 1e18);
        vm.prank(bob);
        pool.liquidate(alice, address(colA), 700e18);
        assertEq(pool.collateralOf(alice, address(colA)), 0);
        assertEq(pool.debtOf(alice), 0);
        assertGt(pool.badDebt(), 0);


    }

    function test_closeFactor_caps_repay() public {
        vm.prank(alice);
        pool.depositCollateral(address(colA), 1e18);
        vm.prank(alice);
        pool.borrow(1000e18);

        oracle.setPrice(address(colA), 900e18); // price drop causes undercollateralization
        uint256 beforeDebt = pool.debtOf(alice);
        vm.prank(bob);
        pool.liquidate(alice, address(colA), 1000e18);
        uint256 afterDebt = pool.debtOf(alice);
        assertGe(afterDebt, beforeDebt / 2);

    }

    function test_withdrawCollateral_healthGate() public {
        vm.prank(alice);
        pool.depositCollateral(address(colA), 1e18);
        vm.prank(alice);
        pool.borrow(1500e18);
        vm.expectRevert(MiniLendingMC_BadDebt.NotHealthy.selector);
        vm.prank(alice);
        pool.withdrawCollateral(address(colA), 0.5e18);
    }

    function test_insufficientCash_withdraw() public {
        // Alice deposits enough so her balance check passes on withdraw.
        vm.prank(alice);
        pool.deposit(300_000e18);

        // Bob borrows against healthy collateral and drains pool cash.
        colA.mint(bob, 400e18);
        vm.prank(bob);
        colA.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        pool.depositCollateral(address(colA), 400e18);
        vm.prank(bob);
        pool.borrow(600_000e18);
        vm.expectRevert(MiniLendingMC_BadDebt.InsufficientCash.selector);
        vm.prank(alice);
        pool.withdraw(250_000e18);

    }
    
}
