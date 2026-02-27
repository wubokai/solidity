// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Test.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {MiniLendingV1} from "../src/day6/MiniLendingV1.sol";
import {MockOracle} from "../src/day6/MockOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract MiniLendingV1Test is Test {
    MockERC20 asset;
    MockERC20 col;
    MockOracle oracle;
    MiniLendingV1 pool;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address liq   = address(0x1);

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        col   = new MockERC20("Collateral", "COL", 18);

        // 1 COL = 2 AST
        oracle = new MockOracle(2e18);

        // params
        uint256 ltvBps = 7500;
        uint256 liqThBps = 8000;
        uint256 liqBonusBps = 500;

        // interest: base=0, slope ~ 5% APR at util=100% (rough)
        // per second ray: APR / secondsPerYear * 1e27
        uint256 secondsPerYear = 365 days;
        uint256 slopeRay = (5e16 * 1e27) / secondsPerYear; // 5% APR
        uint256 baseRay  = 0;

        pool = new MiniLendingV1(asset, col, oracle, ltvBps, liqThBps, liqBonusBps, baseRay, slopeRay);

        // fund users
        asset.mint(alice, 1_000_000e18);
        asset.mint(bob,   1_000_000e18);
        asset.mint(liq,   1_000_000e18);

        col.mint(alice, 1_000_000e18);
        col.mint(bob,   1_000_000e18);

        // approvals
        vm.startPrank(alice);
        asset.approve(address(pool), type(uint256).max);
        col.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(pool), type(uint256).max);
        col.approve(address(pool), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liq);
        asset.approve(address(pool), type(uint256).max);
        vm.stopPrank();
    }

    function test_deposit_withdraw_basic() public {
        vm.startPrank(alice);
        pool.deposit(1000e18);
        assertEq(pool.totalDeposits(), 1000e18);

        pool.withdraw(200e18);
        assertEq(pool.totalDeposits(), 800e18);
        vm.stopPrank();
    }

    

}
