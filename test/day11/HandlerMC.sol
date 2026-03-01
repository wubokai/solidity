// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import {MiniLendingMC_BadDebt} from "../../src/day11/MiniLendingMC_BadDebt.sol";
import {OracleMock} from "../../src/day11/OracleMock.sol";
import {ERC20Mock} from "../../src/day11/ERC20Mock.sol";

contract HandlerMC is Test {

    MiniLendingMC_BadDebt public pool;
    OracleMock public oracle;

    ERC20Mock public asset;
    ERC20Mock public colA;
    ERC20Mock public colB;

    address[] public users;

    // optional ghost accounting
    uint256 public ghostDeposits;
    uint256 public ghostWithdraws;

    constructor(
        MiniLendingMC_BadDebt _pool,
        OracleMock _oracle,
        ERC20Mock _asset,
        ERC20Mock _colA,
        ERC20Mock _colB,
        address[] memory _users
    ) {
        pool = _pool;
        oracle = _oracle;
        asset = _asset;
        colA = _colA;
        colB = _colB;
        users = _users;

        // approve pool for all users (via prank)
        for (uint256 i = 0; i < users.length; i++) {
            address u = users[i];
            vm.startPrank(u);
            asset.approve(address(pool), type(uint256).max);
            colA.approve(address(pool), type(uint256).max);
            colB.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function act_deposit(uint256 seedUser, uint256 amt) external {
        address u = _user(seedUser);
        amt = bound(amt, 1e6, 50_000e18);

        asset.mint(u, amt);
        vm.prank(u);
        try pool.deposit(amt) {
            ghostDeposits += amt;
        } catch {}
        
    }

    function act_withdraw(uint256 seedUser, uint256 amt) external {
        address u = _user(seedUser);
        uint256 bal = pool.depositOf(u);
        if(bal == 0) return;

        amt = bound(amt, 1, bal);
        vm.prank(u);
        try pool.withdraw(amt) {
            ghostWithdraws += amt;
        } catch {}
    }

    function act_depositCollateral(uint256 seedUser, uint256 which, uint256 amt) external {
        address u = _user(seedUser);
        amt = bound(amt, 1e6, 20e18);
        ERC20Mock col = (which % 2 == 0) ? colA : colB;
        col.mint(u,amt);
        vm.prank(u);
        try pool.depositCollateral(address(col), amt) {
            // optional ghost accounting
        } catch {}
    }

    function act_withdrawCollateral(uint256 seedUser, uint256 which, uint256 amt) external {
        address u = _user(seedUser);
        ERC20Mock col = (which % 2 == 0) ? colA : colB;
        uint256 bal = pool.collateralOf(u, address(col));
        if (bal == 0) return;

        amt = bound(amt, 1, bal);
        vm.prank(u);
        try pool.withdrawCollateral(address(col), amt) {
            // optional ghost accounting
        } catch {}
    }

    function act_borrow(uint256 seedUser, uint256 amt) external {
        address u = _user(seedUser);
        amt = bound(amt, 1e6, 30_000e18);
        vm.prank(u);
        try pool.borrow(amt) {
            // optional ghost accounting
        } catch {}

    }

    function act_repay(uint256 seedUser, uint256 amt) external {
        address u = _user(seedUser);
        uint256 d = pool.debtOf(u);
        if(d == 0) return;
        amt = bound(amt, 1, d);
        asset.mint(u, amt);
        vm.prank(u);
        try pool.repay(amt) {} catch {}

    }

    function act_setPrice(uint256 which, uint256 p) external { 
        p = bound(p, 1e14, 10_000e18);
        address token = which % 3 == 0 ? address(asset) : (which % 3 == 1 ? address(colA) : address(colB));
        oracle.setPrice(token, p);

    }

    function act_liquidate(uint256 seedBorrower, uint256 seedLiq, uint256 whichCol, uint256 repayAmt) external {
        address borrower = _user(seedBorrower);
        address liq = _user(seedLiq);
        if (borrower == liq) return;

        repayAmt = bound(repayAmt, 1e6, 20_000e18);
        address col = (whichCol % 2 == 0) ? address(colA) : address(colB);

        // ensure liquidator has asset
        asset.mint(liq, repayAmt);

        vm.prank(liq);
        try pool.liquidate(borrower, col, repayAmt) {} catch {}

    }

    function act_warp(uint256 dt) external { 
        dt = bound(dt, 0, 7 days);
        vm.warp(block.timestamp + dt);
        try pool.accrueInterest() {} catch {}
    }


}