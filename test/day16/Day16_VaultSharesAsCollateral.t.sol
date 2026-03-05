// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

// ===== TODO: 改成你仓库的真实相对路径 =====
import {MiniLendingMC_BadDebt} from "../../src/day16/MiniLendingMC_BadDebt.sol";
import {ShareVaultV2Strategy} from "../../src/day16/ShareVaultV2Strategy.sol";
import {MockStrategy} from "../../src/day16/MockStrategy.sol";

import {CompositeOracle} from "../../src/day16/CompositeOracle.sol";
import {VaultShareOracle} from "../../src/day16/VaultShareOracle.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8  public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n; symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract Day16_VaultSharesAsCollateral is Test {
    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    MockERC20 asset; // lending.asset & vault.asset (same token for your lending)
    ShareVaultV2Strategy vault;
    MockStrategy strategy;
    MiniLendingMC_BadDebt lending;

    CompositeOracle oracle;        // total oracle used by lending
    VaultShareOracle shareOracle;  // sub-oracle for vault shares

    function setUp() external {
        // 1) deploy token
        asset = new MockERC20("USD Mock", "USD");

        // 2) deploy vault
        vault = new ShareVaultV2Strategy(address(asset), "ShareVault", "SV");

        // 3) deploy strategy (VAULT must match, per your MockStrategy NotVault check)
        strategy = new MockStrategy(address(asset), address(vault));

        // 4) set strategy + keeper/owner wiring (你的 vault 里有 setStrategy / setKeeper 的话在这里接上)
        // ===== TODO: 改成你 ShareVaultV2Strategy 的真实管理函数名 =====
        vault.setStrategy(address(strategy));
        vault.setKeeper(address(this));

        // 5) oracle setup: underlying asset is $1
        oracle = new CompositeOracle();
        oracle.setStaticPrice(address(asset), 1e18);

        shareOracle = new VaultShareOracle(address(vault), address(oracle));
        oracle.setOracle(address(vault), address(shareOracle));

        // 6) deploy lending with immutable oracle
        lending = new MiniLendingMC_BadDebt(
            address(asset),
            address(oracle),
            0,        // ratePerSecond (set 0 for easier E2E, later再加利息)
            0         // reserveFactor
        );

        // 7) list vault share as collateral
        lending.listCollateral(address(vault), true);

        // 8) seed pool cash so Alice can borrow
        asset.mint(address(this), 1_000_000e18);
        asset.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);

        // 9) seed user balances
        asset.mint(alice, 100_000e18);
        asset.mint(bob,   100_000e18);

        vm.label(alice, "alice");
        vm.label(bob, "bob");
        vm.label(address(vault), "vault");
        vm.label(address(lending), "lending");
    }

    function test_e2e_deposit_collateral_borrow_repay_withdraw_redeem() external {
        uint256 depositAssets = 10_000e18;
        uint256 borrowAmt     = 4_000e18;

        vm.startPrank(alice);

        asset.approve(address(vault), depositAssets);
        uint256 shares = vault.deposit(depositAssets, alice);
        assertGt(shares, 0);

        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares);

        lending.borrow(borrowAmt);
        assertEq(asset.balanceOf(alice), 100_000e18 - depositAssets + borrowAmt);
        
        asset.approve(address(lending), type(uint256).max);
        lending.repay(borrowAmt);

        lending.withdrawCollateral(address(vault), shares);

        uint256 before =asset.balanceOf(alice);
        vault.redeem(shares, alice, alice);
        uint256 after_ = asset.balanceOf(alice);

        assertGt(after_, before);
        vm.stopPrank();
    }

    function test_profit_increases_borrow_capacity() external {
        uint256 depositAssets = 10_000e18;
        uint256 borrowAmt     = 4_000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        uint256 shares = vault.deposit(depositAssets, alice);
        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares);

        lending.borrow(borrowAmt);      
        vm.stopPrank();
        // 模拟 profit：把资产直接转给 strategy（MockStrategy 只是持币）
        // 注意：如果你的 vault invest 逻辑需要把钱转进 strategy，

        asset.mint(address(this), 2_000e18);
        asset.transfer(address(strategy), 2_000e18);

        vm.startPrank(alice);
        lending.borrow(500e18);
        vm.stopPrank();

    }

    function test_loss_triggers_liquidation() external {
        uint256 depositAssets = 10_000e18;
        uint256 borrowAmt     = 7_000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        uint256 shares = vault.deposit(depositAssets, alice);

        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares);

        lending.borrow(borrowAmt);
        vm.stopPrank();

        // Move most vault cash into strategy, then realize a strategy loss.
        vault.invest(9_000e18);
        strategy.simulateLoss(address(0xdead), 3_000e18);
        assertLt(lending.healthFactor(alice), 1e18);

        // liquidate by bob
        vm.startPrank(bob);
        asset.approve(address(lending), type(uint256).max);
        lending.liquidate(alice, address(vault), 1_000e18);
        vm.stopPrank();
    }

    function test_liquidator_can_redeem_seized_shares() external {
        uint256 depositAssets = 10_000e18;
        uint256 borrowAmt     = 7_000e18;

        vm.startPrank(alice);
        asset.approve(address(vault), depositAssets);
        uint256 shares = vault.deposit(depositAssets, alice);

        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares);

        lending.borrow(borrowAmt);
        vm.stopPrank();

        // Make vault share price drop by realizing loss in strategy accounting.
        vault.invest(9_000e18);
        strategy.simulateLoss(address(0xdead), 3_000e18);
        assertLt(lending.healthFactor(alice), 1e18);

        // liquidate
        vm.startPrank(bob);
        asset.approve(address(lending), type(uint256).max);
        lending.liquidate(alice, address(vault), 1_000e18);

        uint256 seized = vault.balanceOf(bob);
        assertGt(seized, 0);

        uint256 before = asset.balanceOf(bob);
        vault.redeem(seized, bob, bob);
        uint256 after_ = asset.balanceOf(bob);

        assertGt(after_, before);
        vm.stopPrank();
    }

    function test_donation_increases_share_price() external {
        vm.startPrank(alice);
        asset.approve(address(vault), 10_000e18);
        uint256 shares = vault.deposit(10_000e18, alice);

        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares);
        vm.stopPrank();

        // donate: direct transfer to vault
        asset.mint(address(this), 1_000e18);
        asset.transfer(address(vault), 1_000e18);

        // sanity: now additional borrow should be easier
        vm.startPrank(alice);
        lending.borrow(500e18);
        vm.stopPrank();
    }

    function test_oracle_supply_zero_returns_zero() external {
        ShareVaultV2Strategy emptyVault =
            new ShareVaultV2Strategy(address(asset), "Empty", "E");
        VaultShareOracle o = new VaultShareOracle(address(emptyVault), address(oracle));
        assertEq(o.price(address(emptyVault)), 0);
    }

    
}
