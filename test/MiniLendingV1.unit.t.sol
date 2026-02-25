// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "../lib/forge-std/src/Test.sol";
import {MiniLendingV1} from "../src/day6/MiniLendingV1.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

contract MiniLendingV1_Unit is Test {

    MiniLendingV1 public lending;
    MockERC20 public asset;
    MockERC20 public collateral;
    MockOracle public oracle;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address lp    = address(0x1);

    function setUp() external {
        asset = new MockERC20("Asset", "AST", 18);
        collateral = new MockERC20("Collateral", "COL", 18);
        oracle = new MockOracle(2e18); // 1 COL = 2 AST

        lending = new MiniLendingV1(
            asset,
            collateral,
            oracle,
            7500,   // ltvBps
            8500,   // liqThresholdBps
            500,    // liqBonusBps
            1e25,   // baseRateRay
            2e25    // slopeRay
        );
        //lp provides liquidity

        asset.mint(lp, 10_000_000e18);
        vm.startPrank(lp);
        asset.approve(address(lending), type(uint256).max);
        lending.deposit(10_000_000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        asset.approve(address(lending), type(uint256).max);
        collateral.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(lending), type(uint256).max);
        collateral.approve(address(lending), type(uint256).max);
        vm.stopPrank();

    }

    function _mintAll(address u, uint256 aAmt, uint256 cAmt) internal {
        if (aAmt > 0) asset.mint(u, aAmt);
        if (cAmt > 0) collateral.mint(u, cAmt);
    }

    function test_accrue_idempotent_sameTimestamp() external {
        //先让alice持有债务
        _mintAll(alice, 0, 1000e18);
        vm.prank(alice);
        lending.depositCollateral(1000e18);
        vm.prank(alice);
        lending.borrow(1000e18);
        uint256 d0 = lending.totalDebt();
        lending.accrueInterest();
        uint256 d1 = lending.totalDebt();
        lending.accrueInterest();
        uint256 d2 = lending.totalDebt();
        assertEq(d1, d2);
        assertGe(d1, d0);

    }

    function test_accrue_monotonic_afterWarp() external {
        _mintAll(alice, 0, 1000e18);
        vm.prank(alice);
        lending.depositCollateral(1000e18);

        vm.prank(alice);
        lending.borrow(1000e18);

        uint256 d0 = lending.totalDebt();
        vm.warp(block.timestamp + 7 days);
        lending.accrueInterest();

        uint256 d1 = lending.totalDebt();
        assertGe(d1, d0);
        assertGe(lending.totalDeposits(), d1);
    }

    function test_repay_partial_and_full() external {
        _mintAll(alice, 2000e18, 1000e18);
        vm.prank(alice);
        lending.depositCollateral(1000e18);
        vm.prank(alice);
        lending.borrow(1000e18);
        vm.prank(alice);
        lending.repay(300e18);
        uint256 debtAfterPartial = lending.debtOf(alice);
        assertLt(debtAfterPartial, 1000e18);

        vm.prank(alice);
        lending.repay(10_000e18);
        assertEq(lending.debtOf(alice), 0);
        assertEq(lending.debtSharesOf(alice), 0);

    }

    function test_withdrawCollateral_reverts_if_breaksSolvency() external {
        _mintAll(alice, 0, 1000e18);
        vm.prank(alice);
        lending.depositCollateral(1000e18);

        vm.prank(alice);
        lending.borrow(1400e18);
        vm.expectRevert(MiniLendingV1.NotSolvent.selector);
        vm.prank(alice);
        lending.withdrawCollateral(900e18);
    }

    function test_liquidation_path_basic() external {
        _mintAll(alice, 0, 1000e18);
        _mintAll(bob,  5000e18, 0);
        vm.prank(alice);
        lending.depositCollateral(1000e18);
        vm.prank(alice);
        lending.borrow(1400e18);

        oracle.setPrice(1e18);

        uint256 colBefore = lending.collateralOf(alice);

        vm.prank(bob);
        lending.liquidate(alice, 500e18);

        uint256 colAfter = lending.collateralOf(alice);
        assertLt(colAfter, colBefore);

    }

    function test_donation_doesNotChangeTotalDeposits() external {
        _mintAll(alice, 1000e18, 0);
        uint256 td0 = lending.totalDeposits();

        vm.prank(alice);
        asset.transfer(address(lending), 1000e18);

        uint256 td1 = lending.totalDeposits();
        assertEq(td1, td0);

        assertGt(asset.balanceOf(address(lending)), td1);
    }
    

}