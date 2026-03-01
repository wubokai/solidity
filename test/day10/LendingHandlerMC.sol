// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import {MiniLendingMC} from "../../src/day10/MiniLendingMC.sol";
import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";


contract LendingHandlerMC is Test {

    MiniLendingMC public pool;
    MockOracle public oracle;

    MockERC20 public debt;
    MockERC20 public colA;
    MockERC20 public colB;

    address[] public actors;

    constructor(
        MiniLendingMC _pool,
        MockOracle _oracle,
        MockERC20 _debt,
        MockERC20 _colA,
        MockERC20 _colB
    ) {
        pool = _pool;
        oracle = _oracle;
        debt = _debt;
        colA = _colA;
        colB = _colB;

        // create few actors
        actors.push(address(0xA1));
        actors.push(address(0xA2));
        actors.push(address(0xA3));

        for (uint256 i = 0; i < actors.length; i++) {
            address u = actors[i];
            colA.mint(u, 50e18);
            colB.mint(u, 200_000e6);
            debt.mint(u, 50_000e18);

            vm.startPrank(u);
            colA.approve(address(pool), type(uint256).max);
            colB.approve(address(pool), type(uint256).max);
            debt.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function deposit(uint256 seed, uint256 amt, bool useA) external {
        address u = _actor(seed);
        address token = useA ? address(colA) : address(colB);
        amt = bound(amt, 1, useA ? 5e18 : 10_000e6);
        vm.startPrank(u);
        pool.depositCollateral(token, amt);
        vm.stopPrank();
    }

    function withdraw(uint256 seed, uint256 amt, bool useA) external {
        address u = _actor(seed);
        address token = useA ? address(colA) : address(colB);

        uint256 bal = pool.collateralOf(u, token);
        if (bal == 0) return;
        amt = bound(amt, 1, bal);

        vm.startPrank(u);
        try pool.withdrawCollateral(token, amt) {} catch {}
        vm.stopPrank();

    }

    function borrow(uint256 seed, uint256 amt) external {
        address u = _actor(seed);

        amt = bound(amt,1e18,5_000e18);
        vm.startPrank(u);
        try pool.borrow(amt) {} catch {}
        vm.stopPrank();

    }


    function repay(uint256 seed, uint256 amt) external {
        address u = _actor(seed);
        amt = bound(amt,1e18,10_000e18);

        vm.startPrank(u);
        try pool.repay(amt) {} catch {}
        vm.stopPrank();
    }

    function setPrice(uint256 seed, uint256 pA, uint256 pB) external {
        // keep in sane ranges to avoid division edge
        pA = bound(pA, 100e18, 5000e18);
        pB = bound(pB, 0.5e18, 2e18);

        oracle.setPrice(address(colA), pA);
        oracle.setPrice(address(colB), pB);
        // debt fixed at $1 in most setups; keep stable
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 0, 2 days);
        vm.warp(block.timestamp + dt);
        // optionally call accrue
        try pool.accrueInterest() {} catch {}
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }
}