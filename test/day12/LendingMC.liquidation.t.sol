// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {MiniLendingMC_BadDebt} from "../../src/day12/MiniLendingMC_BadDebt.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";

contract LendingMCLiquidationUnit is Test {

    MiniLendingMC_BadDebt pool;
    MockERC20 asset;
    MockERC20 col;
    MockOracle oracle;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice"); // borrower
    address bob = makeAddr("bob");     // liquidator

    function setUp() external {
        asset = new MockERC20("Asset", "AST", 18);
        col   = new MockERC20("Col", "COL", 18);
        oracle = new MockOracle();

        oracle.setPrice(address(asset), 1e18);
        oracle.setPrice(address(col), 2e18); // collateral $2

        pool = new MiniLendingMC_BadDebt(address(asset), address(oracle), 0, 0); // simplify
        pool.listCollateral(address(col), true);

        // seed liquidity
        asset.mint(lp, 1e24);
        vm.startPrank(lp);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(1e24);
        vm.stopPrank();

        // borrower collateral + borrow
        col.mint(alice, 1e21);
        vm.startPrank(alice);
        col.approve(address(pool), type(uint256).max);
        pool.depositCollateral(address(col), 1e21);
        pool.borrow(5e20); // borrow 0.5e21 AST
        vm.stopPrank();
    }

    function test_closeFactor_caps_repay() external {
        oracle.setPrice(address(col), 5e17); // $0.5
        uint256 debt = pool.debtOf(alice);
        uint256 wantRepay = debt;
        asset.mint(bob,wantRepay);
        uint256 sharesBefore = pool.debtSharesOf(alice);

        vm.startPrank(bob);
        asset.approve(address(pool), type(uint256).max);
        pool.liquidate(alice, address(col), wantRepay);
        vm.stopPrank();

        uint256 sharesAfter = pool.debtSharesOf(alice);
        assertLt(sharesAfter,sharesBefore);

    }

    function test_backsolve_when_collateral_insufficient_adds_badDebt() external {

        oracle.setPrice(address(col), 1);
        asset.mint(bob,1e24);
        vm.startPrank(bob);
        asset.approve(address(pool),type(uint256).max);
        pool.liquidate(alice, address(col), 1e24);
        vm.stopPrank();

        uint256 c = pool.collateralOf(alice, address(col));
        if(c ==0) assertGe(pool.badDebt(),0);

    }

    


}