// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import {MiniLendingMC} from "../../src/day10/MiniLendingMC.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";

contract MultiCollateralTest is Test {

    MiniLendingMC pool;
    MockOracle oracle;

    MockERC20 debt; // stable
    MockERC20 colA; // e.g. WETH(18)
    MockERC20 colB; // e.g. USDC(6) or WBTC(8)

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() external {
        oracle = new MockOracle();
        debt = new MockERC20("Debt", "DEBT", 18);
        colA = new MockERC20("ColA", "COLA", 18);
        colB = new MockERC20("ColB", "COLB", 6);

        pool = new MiniLendingMC(address(debt), address(oracle));

        // configure collateral
        pool.configureCollateral(address(colA), true, 0.8e18, 0);
        pool.configureCollateral(address(colB), true, 0.7e18, 0);

        // prices 1e18
        oracle.setPrice(address(debt), 1e18);   // $1
        oracle.setPrice(address(colA), 2000e18); // $2000
        oracle.setPrice(address(colB), 1e18);   // $1

        // liquidity: pool has debt asset to lend
        debt.mint(address(pool), 1_000_000e18);

        // user balances
        colA.mint(alice, 10e18);
        colB.mint(alice, 100_000e6);
        debt.mint(alice, 1_000e18);

        vm.startPrank(alice);
        colA.approve(address(pool), type(uint256).max);
        colB.approve(address(pool), type(uint256).max);
        debt.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        // set interest low for unit tests
        pool.setRatePerSecond(0);
    }

    function test_deposit_two_collaterals_and_health() external {
        vm.startPrank(alice);
        pool.depositCollateral(address(colA), 1e18);       // $2000 * 0.8 = $1600 adj
        pool.depositCollateral(address(colB), 1000e6);    

        pool.borrow(2000e18);
        uint256 hf = pool.healthFactor(alice);
        assertGe(hf, 1e18);
        vm.stopPrank();
    }

    function test_withdraw_should_revert_if_breaks_health() external {
        vm.startPrank(alice);
        pool.depositCollateral(address(colA), 1e18);
        pool.borrow(1500e18);
        
        vm.expectRevert(MiniLendingMC.HealthFactorTooLow.selector);
        pool.withdrawCollateral(address(colA), 0.5e18);
        vm.stopPrank();
    }

    function test_price_drop_makes_liquidatable() external { 

        vm.startPrank(alice);
        pool.depositCollateral(address(colA), 1e18);
        pool.borrow(1500e18);
        vm.stopPrank();

        oracle.setPrice(address(colA), 1200e18);

        uint256 hf = pool.healthFactor(alice);
        assertLt(hf,1e18);
    }

    function test_liquidate_specified_collateralToken() external {

        vm.startPrank(alice);
        pool.depositCollateral(address(colA), 1e18);
        pool.depositCollateral(address(colB), 2000e6);
        pool.borrow(1800e18);
        vm.stopPrank();

        oracle.setPrice(address(colA), 400e18);

        debt.mint(bob, 10_000e18);
        vm.startPrank(bob);
        debt.approve(address(pool), type(uint256).max);

        pool.liquidate(alice, address(colA), 500e18);
        vm.stopPrank();


    }   



}