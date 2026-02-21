// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "../lib/forge-std/src/Test.sol";
import "../src/MiniBank.sol";
import "../src/ForceSend.sol";

contract MiniBankTest is Test {
    MiniBank bank;

    address alice =address(0xA11CE);
    address bob = address(0xB0B);

    receive() external payable{}
    
    function setUp() public {
        bank = new MiniBank();
    }

    function test_DepositUpdatesBalancesAndTotal() public {

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bank.deposit{value: 1 ether}();
        
        assertEq(address(bank).balance, 1 ether);
        assertEq(bank.accountedBalance(), 1 ether);
        assertEq(bank.balances(alice), 1 ether);
        assertEq(bank.excess(), 0);

    }

    function test_ForceSendCreatesExcess() public {

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        bank.deposit{value: 1 ether}();

        assertEq(address(bank).balance, 1 ether);
        assertEq(bank.accountedBalance(), 1 ether);
        assertEq(bank.balances(alice), 1 ether);
        assertEq(bank.excess(), 0);

        ForceSend fs = new ForceSend{value: 2 ether}();

        fs.forceSend(payable(address(bank)));

        assertEq(address(bank).balance, 3 ether);
        assertEq(bank.accountedBalance(), 1 ether);
        assertEq(bank.balances(alice), 1 ether);
        assertEq(bank.excess(), 2 ether);


    }


    function test_WithdrawReducesBalanceAndTotal() public {

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bank.deposit{value: 2 ether}();

        vm.prank(alice);
        bank.withdraw(0.5 ether);

        assertEq(bank.balances(alice), 1.5 ether);
        assertEq(bank.accountedBalance(), 1.5 ether);
        assertEq(address(bank).balance, 1.5 ether);
        
    }

    function test_WithdrawRevertsIfInsufficient() public {

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bank.deposit{value: 1 ether}();

        vm.prank(alice);
        vm.expectRevert();
        bank.withdraw(2 ether);
    }

    function test_SkimOnlyExcess() public {

        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bank.deposit{value: 1 ether}();

        ForceSend fs = new ForceSend{value: 2 ether}();
        fs.forceSend(payable(address(bank)));
        uint256 balance = address(this).balance;
        bank.skim(payable(address(this)));

        assertEq(address(bank).balance, 1 ether);
        assertEq(bank.accountedBalance(),1 ether);
        assertEq(bank.balances(alice), 1 ether);

        assertEq(address(this).balance, balance + 2 ether);

    }

    function test_SkimRevertsIfNotOwner() public {
        vm.deal(alice, 10 ether);
        vm.prank(alice);
        bank.deposit{value: 1 ether}();

        ForceSend fs = new ForceSend{value: 1 ether}();
        fs.forceSend(payable(address(bank)));

        vm.prank(alice);
        vm.expectRevert();
        bank.skim(payable(alice));

    }


    function test_SkimRevertsIfNoExcess() public {
        vm.expectRevert();
        bank.skim(payable(address(this)));

    }
}
