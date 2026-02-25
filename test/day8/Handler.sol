// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day8/MiniLendingV1.2.sol";
import {MockERC20 as Day8MockERC20} from "../../src/day8/MockERC20.sol";

contract Handler is Test {
    MiniLending public pool;
    Day8MockERC20 public token;

    address[] public actors;
    uint256 public constant ACTORS = 5;

    constructor(MiniLending _pool, Day8MockERC20 _token) {
        pool = _pool;
        token = _token;

        // make some deterministic actors
        for (uint256 i = 0; i < ACTORS; i++) {
            address a = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(a);

            token.mint(a, 1_000_000e18);
            vm.prank(a);
            token.approve(address(pool), type(uint256).max);
        }

        // seed pool liquidity from actors[0]
        vm.prank(actors[0]);
        pool.deposit(500_000e18);
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // -------- actions --------

    function actWarp(uint256 dt) external {
        // cap dt to avoid overflow / super long
        dt = bound(dt, 0, 7 days);
        vm.warp(block.timestamp + dt);
    }

    function actAccrue() external {
        pool.accrueInterest();
    }

    function actDeposit(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, 10_000e18);
        if (amount == 0) return;

        vm.prank(a);
        pool.deposit(amount);
    }

    function actWithdraw(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 bal = pool.deposits(a);
        if (bal == 0) return;

        amount = bound(amount, 0, bal);
        if (amount == 0) return;

        vm.prank(a);
        // withdraw can revert due to insufficient cash; swallow reverts in handler
        try pool.withdraw(amount) {} catch {}
    }

    function actBorrow(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, 5_000e18);
        if (amount == 0) return;

        vm.prank(a);
        try pool.borrow(amount) {} catch {}
    }

    function actRepay(uint256 seed, uint256 amount) external {
        address a = _actor(seed);

        uint256 debt = pool.debtOf(a);
        if (debt == 0) return;

        amount = bound(amount, 0, debt + 1_000e18);
        if (amount == 0) return;

        vm.prank(a);
        try pool.repay(amount) {} catch {}
    }

    // optional: donation to test accounting robustness
    function actDonate(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        amount = bound(amount, 0, 1_000e18);
        if (amount == 0) return;

        vm.prank(a);
        token.transfer(address(pool), amount);
    }
}