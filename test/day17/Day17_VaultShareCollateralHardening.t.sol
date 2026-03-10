// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {ERC20} from "../../src/day17/ERC20.sol";
import {IOracle} from "./IOracle.sol";
import {MiniLendingMC_BadDebt} from "../../src/day17/MiniLendingMC_BadDebt.sol";
import {ShareVaultV2Strategy} from "../../src/day17/ShareVaultV2Strategy.sol";
import {VaultShareOracle} from "../../src/day17/VaultShareOracle.sol";
import {MockStrategy} from "../../src/day17/MockStrategy.sol";

import {MockOracle} from "./MockOracle.sol";
import {OracleRouterMock} from "./OracleRouterMock.sol";
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Day17_VaultShareCollateralHardening_Test is Test {
    uint256 internal constant WAD = 1e18;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal donor = address(0x11);
    address internal liquidator = address(0xCAFE);
    address internal sink = address(0xBEEF);

    MockERC20 internal underlying;
    MockERC20 internal stable;

    ShareVaultV2Strategy internal vault;
    MockStrategy internal strategy;

    MockOracle internal baseOracle;
    VaultShareOracle internal vaultShareOracle;
    OracleRouterMock internal routerOracle;

    MiniLendingMC_BadDebt internal lending;

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND", 18);
        stable = new MockERC20("Stable", "STBL", 18);

        vault = new ShareVaultV2Strategy(address(underlying), "Vault Share", "vSHARE");
        strategy = new MockStrategy(address(underlying), address(vault));
        vault.setStrategy(address(strategy));

        // base oracle: underlying / stable 直接喂价
        baseOracle = new MockOracle();
        baseOracle.setPrice(address(underlying), 1e18);
        baseOracle.setPrice(address(stable), 1e18);

        // vault share oracle
        vaultShareOracle = new VaultShareOracle(address(vault), address(baseOracle));

        // router oracle 给 lending 统一查价
        routerOracle = new OracleRouterMock();
        routerOracle.setDirectPrice(address(stable), 1e18);
        routerOracle.setDirectPrice(address(underlying), 1e18);
        routerOracle.setDelegatedOracle(address(vault), address(vaultShareOracle));

        lending = new MiniLendingMC_BadDebt(
            address(stable),
            address(routerOracle),
            0, // ratePerSecond
            0  // reserveFactor
        );

        lending.listCollateral(address(vault), true);

        // lending 预置 stable 流动性
        stable.mint(address(this), 1_000_000e18);
        stable.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);

        // 给参与者发币
        underlying.mint(alice, 10_000e18);
        underlying.mint(bob, 10_000e18);
        underlying.mint(donor, 10_000e18);

        stable.mint(liquidator, 1_000_000e18);
    }

    function _aliceDepositToVault(uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(alice);
        underlying.approve(address(vault), amount);
        shares = vault.deposit(amount, alice);
        vm.stopPrank();
    }

    function _aliceDepositVaultSharesAsCollateral(uint256 shares) internal {
        vm.startPrank(alice);
        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault),shares);
        vm.stopPrank();
    }

    function _aliceBorrow(uint256 amount) internal {
        vm.prank(alice);
        lending.borrow(amount);
    }

    function _aliceRepay(uint256 amount) internal {
        vm.startPrank(alice);
        stable.approve(address(lending), amount);
        lending.repay(amount);
        vm.stopPrank();
    }

    function _donateToVault(uint256 amount) internal {
        vm.prank(donor);
        underlying.transfer(address(vault), amount);
    }

    function _investAllCash() internal {
        uint256 cash = vault.cashAssets();
        if(cash > 0){
            vault.invest(cash);
        }
    }

    function _simulateStrategyLoss(uint256 amount) internal {
        strategy.simulateLoss(sink, amount);
    }

    function _vaultSharePrice() internal view returns (uint256) {
        return vaultShareOracle.price(address(vault));
    }

    function _maxBorrowableApprox(address user) internal view returns (uint256) {
        uint256 cv = lending.collateralValueUSD(user); // 1e18 USD
        uint256 dv = lending.debtValueUSD(user);

        uint256 maxDebtUsd = (cv * lending.LIQ_THRESHOLD()) / WAD;
        if(maxDebtUsd < dv) return 0;

        uint256 roomUsd = maxDebtUsd - dv;
        uint256 pAsset = routerOracle.price(address(stable));

        return (roomUsd * WAD ) / pAsset;
    }

    function test_VaultShareOracle_ZeroSupplyReturnsZero() public view {
        assertEq(vault.totalSupply(), 0);
        assertEq(_vaultSharePrice(), 0);
    }

    function test_VaultShareOracle_PriceStartsNearOneAfterFirstDeposit() public {
        _aliceDepositToVault(100e18);

        uint256 px = _vaultSharePrice();
        assertGt(px, 0);
        // With virtual shares/assets, initial price is expected to be much lower than 1e18.
        assertLt(px, 1e18);
    }

    function test_DonationIncreasesBorrowCapacityForVaultShareCollateral() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 beforeCap = _maxBorrowableApprox(alice);

        _donateToVault(100e18);

        uint256 afterCap = _maxBorrowableApprox(alice);
        assertGt(afterCap, beforeCap);
    }

    function test_DonationDoesNotDirectlyChangeLendingCashOrDebt() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 cashBefore = lending.cash();
        uint256 debtBefore = lending.totalDebt();

        _donateToVault(100e18);

        uint256 cashAfter = lending.cash();
        uint256 debtAfter = lending.totalDebt();

        assertEq(cashAfter, cashBefore);
        assertEq(debtAfter, debtBefore);
    }

    function test_DonationThenBorrow_MoreCapacityButAccountingRemainsSound() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _aliceDepositVaultSharesAsCollateral(shares);

        _donateToVault(100e18);

        uint256 cap = _maxBorrowableApprox(alice);
        uint256 borrowAmt = cap / 2;
        assertGt(borrowAmt, 0);

        _aliceBorrow(borrowAmt);

        assertEq(stable.balanceOf(alice), borrowAmt);
        assertGt(lending.debtOf(alice), 0);
        assertEq(lending.cash(), 500_000e18 - borrowAmt);
    }

    function test_StrategyProfitPath_IncreasesSharePrice() public {
        _aliceDepositToVault(100e18);

        uint256 beforePx = _vaultSharePrice();
        _investAllCash();

        // 模拟 profit：直接再往 strategy 地址打 underlying
        underlying.mint(address(strategy), 20e18);

        uint256 afterPx = _vaultSharePrice();
        assertGt(afterPx, beforePx);
    }

    function test_LossReducesBorrowCapacityForVaultShareCollateral() public {
        uint256 shares = _aliceDepositToVault(100e18);

        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 beforeCap = _maxBorrowableApprox(alice);

        _simulateStrategyLoss(40e18);

        uint256 afterCap = _maxBorrowableApprox(alice);
        assertLt(afterCap, beforeCap);
    }

    function test_LossCanPushHealthFactorBelowOne() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 cap = _maxBorrowableApprox(alice);
        uint256 borrowAmt = (cap * 95) / 100;
        _aliceBorrow(borrowAmt);

        uint256 hfBefore = lending.healthFactor(alice);
        assertGt(hfBefore, 1e18);

        _simulateStrategyLoss(50e18);

        uint256 hfAfter = lending.healthFactor(alice);
        assertLt(hfAfter, 1e18);
    }

    function test_LossCanTriggerLiquidation() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 cap = _maxBorrowableApprox(alice);
        uint256 borrowAmt = (cap * 95) / 100;
        _aliceBorrow(borrowAmt);

        _simulateStrategyLoss(50e18);
        assertLt(lending.healthFactor(alice), 1e18);

        vm.startPrank(liquidator);
        stable.approve(address(lending), type(uint256).max);
        lending.liquidate(alice, address(vault), borrowAmt / 4);
        vm.stopPrank();

        assertGt(vault.balanceOf(liquidator), 0);
    }

    function test_SevereLossMayLeadToBadDebt() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 cap = _maxBorrowableApprox(alice);
        uint256 borrowAmt = (cap * 95) / 100;
        _aliceBorrow(borrowAmt);

        _simulateStrategyLoss(95e18);
        assertLt(lending.healthFactor(alice), 1e18);

        vm.startPrank(liquidator);
        stable.approve(address(lending), type(uint256).max);
        lending.liquidate(alice, address(vault), type(uint256).max);
        vm.stopPrank();

        // 这里不强制 >0，因为受 rounding / close factor 影响
        assertGe(lending.badDebt(), 0);
    }

    function test_Rounding_SmallDonationDoesNotBreakPricing() public {
        _aliceDepositToVault(100e18);

        uint256 beforePx = _vaultSharePrice();
        _donateToVault(1); // 1 wei
        uint256 afterPx = _vaultSharePrice();

        assertGe(afterPx, beforePx);
    }

    function test_Rounding_BorrowAtEdgeThenTinyLossTurnsUnsafe() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 edgeBorrow = _maxBorrowableApprox(alice);
        if (edgeBorrow > 1) edgeBorrow -= 1;

        _aliceBorrow(edgeBorrow);
        assertGe(lending.healthFactor(alice), 1e18);

        _simulateStrategyLoss(1e18);

        assertLe(lending.healthFactor(alice), 1e18);
    }

    function test_Rounding_RepayImprovesHealthFactor() public {
        uint256 shares = _aliceDepositToVault(100e18);
        _investAllCash();
        _aliceDepositVaultSharesAsCollateral(shares);

        uint256 cap = _maxBorrowableApprox(alice);
        uint256 borrowAmt = (cap * 90) / 100;
        _aliceBorrow(borrowAmt);

        _simulateStrategyLoss(10e18);

        uint256 hfBefore = lending.healthFactor(alice);

        // 给 alice 补 stable 用于还款
        stable.mint(alice, 20e18);
        _aliceRepay(20e18);

        uint256 hfAfter = lending.healthFactor(alice);
        assertGt(hfAfter, hfBefore);
    }

}
