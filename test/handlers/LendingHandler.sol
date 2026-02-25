// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "../../lib/forge-std/src/Test.sol";
import {MiniLendingV1} from "../../src/day6/MiniLendingV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOracle} from "../mocks/MockOracle.sol";

contract D7LendingHandler is Test {

    MiniLendingV1 public lending;
    MockERC20 public collateral;
    MockERC20 public asset;
    MockOracle public oracle;

    address[] public actors;

    uint256 public lastDebtAfterPureAccrue;
    bool public didPureAccrueSinceLast;

    constructor(
        MiniLendingV1 _lending,
        MockERC20 _collateral,
        MockERC20 _asset,
        MockOracle _oracle,
        address[] memory _actors
    ){
        lending = _lending;
        collateral = _collateral;
        asset = _asset;
        oracle = _oracle;
        actors = _actors;

        lastDebtAfterPureAccrue = lending.totalDebt();
        didPureAccrueSinceLast = false;
    }

    function _actor(uint256 seed) internal view returns(address){
        return actors[seed%actors.length];
    }

    function _boundNonZero(uint256 x, uint256 lo, uint256 hi) internal pure returns(uint256){
        if(hi < lo ) return lo;
        x = x % (hi - lo + 1);
        if(x == 0) x = lo == 0? 1 : lo;
        return x; 
    }

    function _mintAndApprove(address user, uint256 aAmt, uint256 cAmt) internal {
        if(aAmt > 0) asset.mint(user,aAmt);
        if(cAmt > 0) collateral.mint(user,cAmt);
        vm.startPrank(user);
        asset.approve(address(lending), type(uint256).max);
        collateral.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    
    }

    function _markNotPureAccrue() internal {
        didPureAccrueSinceLast = false;
    }

    function act_deposit(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        _mintAndApprove(user, amt, 0);

        vm.prank(user);
        lending.deposit(amt);

        _markNotPureAccrue();
    }

    function act_withdraw(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        vm.prank(user);
        try lending.withdraw(amt) {} catch {}

        _markNotPureAccrue();
    }

    function act_depositCollateral(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        _mintAndApprove(user, 0, amt);

        vm.prank(user);
        lending.depositCollateral(amt);
        _markNotPureAccrue();

    }

    function act_withdrawCollateral(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        vm.prank(user);
        try lending.withdrawCollateral(amt) {} catch {}
        _markNotPureAccrue();    
    }


    function act_borrow(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        vm.prank(user);
        try lending.borrow(amt) {} catch {}
        _markNotPureAccrue();
    }

    function act_repay(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        vm.prank(user);
        try lending.repay(amt) {} catch {}
        _markNotPureAccrue();
    }

    function act_liquidate(uint256 seedUser, uint256 seedLiq, uint256 repayAmt) external {
        address user = _actor(seedUser);
        address liq = _actor(seedLiq);
        if (user == liq) liq = actors[(seedLiq + 1) % actors.length];
        repayAmt = _boundNonZero(repayAmt, 1, 1e24);

        _mintAndApprove(liq, repayAmt, 0);
        vm.prank(liq);
        try lending.liquidate(user, repayAmt) {} catch {}
        _markNotPureAccrue();


    }

    function act_warpAndAccrue(uint256 dt) external {
        dt = dt% 30 days;
        if(dt == 0 ) dt =  1;
        vm.warp(block.timestamp + dt);
        lending.accrueInterest();

        didPureAccrueSinceLast = true;
        lastDebtAfterPureAccrue = lending.totalDebt();

    }

    function act_donation(uint256 seed, uint256 amt) external {
        address user = _actor(seed);
        amt = _boundNonZero(amt, 1, 1e24);

        asset.mint(user, amt);
        vm.prank(user);
        asset.transfer(address(lending), amt);
        _markNotPureAccrue();
    }

    function act_setPrice(uint256 newPrice) external {
        newPrice = _boundNonZero(newPrice, 1e6, 1e30);
        oracle.setPrice(newPrice);
        _markNotPureAccrue();
    }
}



