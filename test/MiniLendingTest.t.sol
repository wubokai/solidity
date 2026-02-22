// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "lib/forge-std/src/Test.sol";
import {D4MiniLending} from "../src/day4/D4MiniLending.sol";
import {MockUSD} from "../src/day4/MockUSD.sol";

contract MiniLendingTest is Test {
    
    MockUSD usd;
    D4MiniLending lending;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        usd = new MockUSD();
        lending = new D4MiniLending(usd);

        usd.mint(address(this), 1_000_000e18);
        usd.approve(address(lending), type(uint256).max);
        lending.fund(1_000_000e18);

        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);

        usd.mint(alice, 1_000_000e18);
        vm.prank(alice);
        usd.approve(address(lending), type(uint256).max);
    }

    function testDepositAndBorrowWithinLTV() public {

        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();

        vm.prank(alice);
        lending.borrow(1000e18);

        assertEq(usd.balanceOf(alice),1_000_000e18 + 1000e18);
        assertEq(lending.debt(alice), 1001e18);
        assertEq(lending.collateralETH(alice), 1 ether);

    }

    function testBorrowRevertIfExceedMax() public {
        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert(D4MiniLending.BorrowExceedsLimit.selector);
        lending.borrow(2000e18);
    }
    
    function testRepayPartialAndFull() public {
        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();
        vm.prank(alice);
        lending.borrow(1000e18);

        uint256 d0 = lending.debt(alice);

        vm.prank(alice);
        lending.repay(200e18);
        assertEq(lending.debt(alice), d0 - 200e18);

        vm.prank(alice);
        lending.repay(type(uint256).max);
        assertEq(lending.debt(alice), 0);
    }

    function testWithdrawRevertIfWouldBreakHealth() public {
        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();

        vm.prank(alice);
        lending.borrow(1000e18);

        vm.prank(alice);
        vm.expectRevert(D4MiniLending.DebtTooHighAfterWithdraw.selector);
        lending.withdrawCollateral(0.9 ether);

    }

    function testWithdrawAllAfterRepayAll() public {
        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();
        vm.prank(alice);
        lending.borrow(1000e18);
        vm.prank(alice);
        lending.repay(type(uint256).max);

        uint256 b = alice.balance;
        vm.prank(alice);
        lending.withdrawCollateral(1 ether);

        assertEq(lending.collateralETH(alice), 0);
        assertEq(lending.debt(alice), 0);
        assertEq(alice.balance, b + 1 ether);

    }


    function testBorrowFeeAccounting() public {
        vm.prank(alice);
        lending.depositCollateral{value: 1 ether}();
        vm.prank(alice);
        lending.borrow(1000e18);
        assertEq(lending.debt(alice), 1001e18);
    }

    function testFuzz_borrowNeverExceedsMax(uint96 cWei, uint96 amt) public {
        uint256 collateral = bound(uint256(cWei), 0.01 ether, 50 ether);

        vm.prank(alice);
        lending.depositCollateral{value: collateral}();

        uint256 maxB = lending.maxBorrowUSD(alice);

        uint256 borrowAmt = bound(uint256(amt), 0, maxB * 2);

        uint256 fee = (borrowAmt * lending.BORROW_FEE_BPS()) / 10_000;
        uint256 newDebt = borrowAmt + fee;

        vm.prank(alice);
        if (borrowAmt == 0) {
            vm.expectRevert(D4MiniLending.ZeroAmount.selector);
            lending.borrow(borrowAmt);
        } else if (newDebt > maxB) {
            vm.expectRevert(D4MiniLending.BorrowExceedsLimit.selector);
            lending.borrow(borrowAmt);
        } else {
            lending.borrow(borrowAmt);
            assertEq(lending.debt(alice), newDebt);
        }
    }

}