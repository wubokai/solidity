// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;


import "lib/forge-std/src/Test.sol";
import {MiniVault} from "../src/MiniVault.sol";
import {ERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20{
    constructor(
        string memory name_,
        string memory symbol_
    ) ERC20(name_,symbol_){}

    function mint(address to, uint256 amount) external{
        _mint(to, amount);
    }
}

contract MiniVaultTest is Test{
    MockERC20 asset;
    MiniVault vault;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        asset = new MockERC20("Mock USD", "mUSD");
        vault = new MiniVault(asset,"MiniVault share","mSHARE");

        asset.mint(alice, 1_000e18);
        asset.mint(bob, 1_000e18);

        vm.prank(alice);
        asset.approve(address(vault), type(uint256).max);

        vm.prank(bob);
        asset.approve(address(vault), type(uint256).max);

    }

    function test_Deposit_FirstUser_1to1() public {
        vm.prank(alice);
        uint256 shares = vault.deposit(100e18, alice);

        assertEq(shares,100e18,"first deposit should be 1:1 shares");
        assertEq(vault.totalAssets(),100e18,"vault asstes");
        assertEq(vault.totalSupply(),100e18,"vault shares");
        assertEq(vault.balanceOf(alice),100e18,"alice shares");
        assertEq(asset.balanceOf(alice), 900e18, "alice asset decreased");
    }

    function test_Deposit_SecondUser_AfterYield_GetsFewerShares() public {

        vm.prank(alice);
        vault.deposit(100e18, alice);
        asset.mint(address(vault), 100e18);

        vm.prank(bob);
        uint256 bobShares = vault.deposit(100e18, bob);
        
        assertEq(bobShares, 50e18, "bob shares should be ~50e18");
        assertEq(vault.totalAssets(), 300e18, "vault assets after bob deposit");
        assertEq(vault.totalSupply(), 150e18, "total shares after bob deposit");
        assertEq(vault.balanceOf(bob), 50e18, "bob share balance");
    }

    function test_Withdraw_AfterYield_BurnsCorrectShares() public {
        vm.prank(alice);
        vault.deposit(100e18, alice);

        asset.mint(address(vault), 100e18);
        uint256 aliceSharesBefore = vault.balanceOf(alice);
        uint256 aliceAssetsBefore = asset.balanceOf(alice);

        vm.prank(alice);
        uint256 burned = vault.withdraw(100e18, alice, alice);

        assertEq(burned,50e18,"should burn 50 shares for 100 assets");
        assertEq(vault.balanceOf(alice), aliceSharesBefore - 50e18, "alice shares after burn");
        assertEq(asset.balanceOf(alice), aliceAssetsBefore + 100e18, "alice got assets back");
    }

    function test_Deposit_RevertOnZeroAssets() public {
        vm.prank(alice);
        vm.expectRevert(MiniVault.ZeroAssets.selector);
        vault.deposit(0,alice);

    }    

    function test_Withdraw_RevertIfInsufficientShares() public {
        vm.prank(alice);
        vm.expectRevert();
        vault.withdraw(1e18,alice,alice);

    }

    function testFuzz_DepositThenWithdraw_NoYield(uint96 amt) public {
        uint256 assets = uint256(amt);
        vm.assume(assets>0);
        vm.assume(assets <= 1_000e18);

        vm.startPrank(alice);
        uint256 shares = vault.deposit(assets,alice);
        vault.withdraw(assets, alice, alice);
        vm.stopPrank();

        assertEq(vault.totalAssets(), 0, "vault should have no assets");
        assertEq(vault.totalSupply(),0, "vault should have no shares");
        assertEq(asset.balanceOf(alice),1_000e18, "alice should have all assets back");
        assertEq(vault.balanceOf(alice),0, "alice should have no shares");
        assertTrue(shares>0,"should be > 0");

    }

    function test_Withdraw_BySpender_WithAllowance() public {
    // Alice deposit 100
    vm.prank(alice);
    vault.deposit(100e18, alice);

    // yield +100 => A=200, S=100
    asset.mint(address(vault), 100e18);

    // Alice 给 Bob 授权 shares
    // Alice withdraw 100 assets will burn 50 shares
    uint256 sharesNeeded = vault.previewWithdraw(100e18);
    assertEq(sharesNeeded, 50e18);

    vm.prank(alice);
    vault.approve(bob, sharesNeeded);

    uint256 aliceAssetBefore = asset.balanceOf(alice);

    // Bob 代替 Alice withdraw 给 Alice
    vm.prank(bob);
    uint256 burned = vault.withdraw(100e18, alice, alice);

    assertEq(burned, sharesNeeded);
    assertEq(asset.balanceOf(alice), aliceAssetBefore + 100e18, "alice received assets");
    assertEq(vault.allowance(alice, bob), 0, "allowance should be spent");
    }

    function test_Withdraw_BySpender_RevertIfAllowanceInsufficient() public {
    // Alice deposit 100
    vm.prank(alice);
    vault.deposit(100e18, alice);

    // yield +100 => A=200, S=100
    asset.mint(address(vault), 100e18);

    uint256 sharesNeeded = vault.previewWithdraw(100e18); // 50e18

    // Alice 只给 Bob 授权 1 shares（明显不够）
    vm.prank(alice);
    vault.approve(bob, 1e18);

    vm.prank(bob);
    vm.expectRevert(MiniVault.InsufficientAllowance.selector);
    vault.withdraw(100e18, alice, alice);
    }

}

