// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

// ===== adjust these paths to your repo =====
import {ERC20} from "../../src/day18/ERC20.sol";
import {ShareVaultV2Strategy} from "../../src/day18/ShareVaultV2Strategy.sol";
import {MockStrategy} from "../../src/day18/MockStrategy.sol";
import {MockOracle} from "../../src/day18/MockOracle.sol";
import {VaultShareOracle} from "../../src/day18/VaultShareOracle.sol";
import {MiniLendingMC_BadDebt} from "../../src/day18/MiniLendingMC_BadDebt.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Day18CompositeAttackSurfaceTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal asset;
    MockERC20 internal stable;

    ShareVaultV2Strategy internal vault;
    MockStrategy internal strategy;

    MockOracle internal baseOracle;
    VaultShareOracle internal shareOracle;

    MiniLendingMC_BadDebt internal lending;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal liquidator = address(0xBEEF);
    address internal sink = address(0xDEAD);

    function setUp() public {
        // ---------- tokens ----------
        asset = new MockERC20("Asset", "AST", 18);
        stable = new MockERC20("Stable", "USD", 18);

        // ---------- vault + strategy ----------
        vault = new ShareVaultV2Strategy(address(asset), "Vault Share", "vAST");
        strategy = new MockStrategy(address(asset), address(vault));
        vault.setStrategy(address(strategy));

        // ---------- oracle ----------
        baseOracle = new MockOracle();
        baseOracle.setPrice(address(asset), 1e18); // 1 AST = 1 USD initially
        baseOracle.setPrice(address(stable), 1e18); // 1 USD = 1 USD

        // share oracle gives price(vaultShare)
        shareOracle = new VaultShareOracle(address(vault), address(baseOracle));

        // ---------- lending ----------
        // constructor(address _asset, address _oracle, uint256 _ratePerSecond, uint256 _reserveFactor)
        lending = new MiniLendingMC_BadDebt(
            address(stable),
            address(baseOracle),
            0,          // simpler tests: no interest drift by default
            0.1e18      // 10% reserve factor, not important for most tests
        );

        // list collateral
        lending.listCollateral(address(vault), true);

        // IMPORTANT:
        // MiniLendingMC_BadDebt has a single oracle for all assets/collaterals.
        // So for vault shares, we must set the vault-share price directly into baseOracle
        // whenever vault conditions change.
        _syncVaultSharePriceToOracle();

        // ---------- mint balances ----------
        asset.mint(alice, 2_000_000e18);
        asset.mint(bob, 2_000_000e18);

        stable.mint(address(this), 5_000_000e18);
        stable.mint(alice, 1_000_000e18);
        stable.mint(bob, 1_000_000e18);
        stable.mint(liquidator, 5_000_000e18);

        // ---------- seed lending pool cash ----------
        stable.approve(address(lending), type(uint256).max);
        lending.deposit(3_000_000e18);

        // ---------- approvals ----------
        vm.startPrank(alice);
        asset.approve(address(vault), type(uint256).max);
        stable.approve(address(lending), type(uint256).max);
        vault.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(vault), type(uint256).max);
        stable.approve(address(lending), type(uint256).max);
        vault.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        stable.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================================
    // helpers
    // ============================================================

    function _syncVaultSharePriceToOracle() internal {
        uint256 px = shareOracle.price(address(vault));
        baseOracle.setPrice(address(vault), px);
    }

    function _depositIntoVault(address user, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(user);
        shares = vault.deposit(amount, user);
        vm.stopPrank();

        _syncVaultSharePriceToOracle();
    }

    function _depositCollateralFromVaultShares(address user, uint256 shares) internal {
        vm.startPrank(user);
        lending.depositCollateral(address(vault), shares);
        vm.stopPrank();
    }

    function _mintVaultPositionAndPostCollateral(address user, uint256 assetAmount) internal returns (uint256 shares) {
        shares = _depositIntoVault(user, assetAmount);
        _depositCollateralFromVaultShares(user, shares);
    }

    function _borrow(address user, uint256 amount) internal {
        vm.prank(user);
        lending.borrow(amount);
    }

    function _repay(address user, uint256 amount) internal {
        vm.prank(user);
        lending.repay(amount);
    }

    function _donateToVault(uint256 amount) internal {
        asset.mint(address(this), amount);
        asset.transfer(address(vault), amount);
        _syncVaultSharePriceToOracle();
    }

    function _investAllVaultCash() internal {
        uint256 cash = asset.balanceOf(address(vault));
        if (cash > 0) {
            vault.invest(cash);
            _syncVaultSharePriceToOracle();
        }
    }

    function _simulateStrategyProfit(uint256 amount) internal {
        asset.mint(address(strategy), amount);
        _syncVaultSharePriceToOracle();
    }

    function _simulateStrategyLoss(uint256 amount) internal {
        strategy.simulateLoss(sink, amount);
        _syncVaultSharePriceToOracle();
    }

    function _setUnderlyingPrice(uint256 newPrice) internal {
        baseOracle.setPrice(address(asset), newPrice);

        // vault share price depends on underlying price too
        uint256 sharePx = shareOracle.price(address(vault));
        baseOracle.setPrice(address(vault), sharePx);
    }

    function _poolCash() internal view returns (uint256) {
        return stable.balanceOf(address(lending));
    }

    function _totalDebt() internal view returns (uint256) {
        return lending.totalDebt();
    }

    function _debtOf(address user) internal view returns (uint256) {
        return lending.debtOf(user);
    }

    function _healthFactor(address user) internal view returns (uint256) {
        return lending.healthFactor(user);
    }

    function _sharePrice() internal view returns (uint256) {
        return shareOracle.price(address(vault));
    }

    function _collateralValue(address user) internal view returns (uint256) {
        return lending.collateralValueUSD(user);
    }

    // ============================================================
    // 1. donation / profit / loss propagation
    // ============================================================

    function test_DonationImprovesCollateralValueButNotPoolCash() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 sharePriceBefore = _sharePrice();
        uint256 collateralValueBefore = _collateralValue(alice);
        uint256 poolCashBefore = _poolCash();
        uint256 totalDebtBefore = _totalDebt();

        _donateToVault(500e18);

        uint256 sharePriceAfter = _sharePrice();
        uint256 collateralValueAfter = _collateralValue(alice);
        uint256 poolCashAfter = _poolCash();
        uint256 totalDebtAfter = _totalDebt();

        assertGt(sharePriceAfter, sharePriceBefore, "share price should rise");
        assertGt(collateralValueAfter, collateralValueBefore, "collateral value should rise");
        assertEq(poolCashAfter, poolCashBefore, "pool cash unchanged");
        assertEq(totalDebtAfter, totalDebtBefore, "total debt unchanged");
    }

    function test_StrategyProfitImprovesCollateralValueButNotPoolCash() public {
        _depositIntoVault(alice, 1_000e18);
        _investAllVaultCash();

        uint256 shares = vault.balanceOf(alice);
        _depositCollateralFromVaultShares(alice, shares);

        uint256 sharePriceBefore = _sharePrice();
        uint256 collateralValueBefore = _collateralValue(alice);
        uint256 poolCashBefore = _poolCash();
        uint256 totalDebtBefore = _totalDebt();

        _simulateStrategyProfit(400e18);

        uint256 sharePriceAfter = _sharePrice();
        uint256 collateralValueAfter = _collateralValue(alice);
        uint256 poolCashAfter = _poolCash();
        uint256 totalDebtAfter = _totalDebt();

        assertGt(sharePriceAfter, sharePriceBefore, "profit should raise share price");
        assertGt(collateralValueAfter, collateralValueBefore, "profit should raise collateral value");
        assertEq(poolCashAfter, poolCashBefore, "pool cash unchanged");
        assertEq(totalDebtAfter, totalDebtBefore, "total debt unchanged");
    }

    function test_StrategyLossReducesCollateralValueAndCanTriggerLiquidation() public {
        _depositIntoVault(alice, 1_000e18);
        _investAllVaultCash();

        uint256 shares = vault.balanceOf(alice);
        _depositCollateralFromVaultShares(alice, shares);

        uint256 collateralValueBefore = _collateralValue(alice);
        uint256 safeBorrow = (collateralValueBefore * 60 / 100); // below threshold
        _borrow(alice, safeBorrow);

        uint256 hfBefore = _healthFactor(alice);
        assertGt(hfBefore, 1e18, "position starts healthy");

        _simulateStrategyLoss(500e18);

        uint256 collateralValueAfter = _collateralValue(alice);
        uint256 hfAfter = _healthFactor(alice);

        assertLt(collateralValueAfter, collateralValueBefore, "loss reduces collateral value");
        assertLt(hfAfter, hfBefore, "loss reduces HF");
        assertLt(hfAfter, 1e18, "position becomes liquidatable");

        uint256 debtBefore = _debtOf(alice);

        vm.prank(liquidator);
        lending.liquidate(alice, address(vault), debtBefore / 2);

        uint256 debtAfter = _debtOf(alice);
        assertLt(debtAfter, debtBefore, "liquidation should reduce debt");
    }

    // ============================================================
    // 2. oracle shocks
    // ============================================================

    function test_OracleUpShockImprovesHFWithoutChangingPoolCash() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 50 / 100);

        uint256 hfBefore = _healthFactor(alice);
        uint256 poolCashBefore = _poolCash();
        uint256 totalDebtBefore = _totalDebt();

        _setUnderlyingPrice(1.5e18);

        uint256 hfAfter = _healthFactor(alice);
        uint256 poolCashAfter = _poolCash();
        uint256 totalDebtAfter = _totalDebt();

        assertGt(hfAfter, hfBefore, "higher price improves HF");
        assertEq(poolCashAfter, poolCashBefore, "oracle change shouldn't change pool cash");
        assertEq(totalDebtAfter, totalDebtBefore, "oracle change shouldn't change total debt");
    }

    function test_OracleDownShockCanCreateBadDebtInSevereCase() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 75 / 100); // near threshold

        uint256 badDebtBefore = lending.badDebt();

        _setUnderlyingPrice(0.2e18); // 80% crash

        assertLt(_healthFactor(alice), 1e18, "should be liquidatable");

        vm.prank(liquidator);
        lending.liquidate(alice, address(vault), type(uint256).max);

        uint256 badDebtAfter = lending.badDebt();
        assertGe(badDebtAfter, badDebtBefore, "severe shock may realize bad debt");
    }

    function test_ZeroPriceMakesVaultCollateralWorthless() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        _setUnderlyingPrice(0);

        uint256 sharePriceAfter = _sharePrice();
        uint256 collateralValueAfter = _collateralValue(alice);

        assertEq(sharePriceAfter, 0, "share price should go to zero");
        assertEq(collateralValueAfter, 0, "collateral value should go to zero");

        vm.startPrank(alice);
        vm.expectRevert(); // borrow should fail because HF check fails
        lending.borrow(1e18);
        vm.stopPrank();
    }

    // ============================================================
    // 3. liquidation boundaries
    // ============================================================

    function test_CannotLiquidateHealthyPosition() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 30 / 100);

        assertGe(_healthFactor(alice), 1e18, "healthy");

        vm.startPrank(liquidator);
        vm.expectRevert(MiniLendingMC_BadDebt.Healthy.selector);
        lending.liquidate(alice, address(vault), 1e18);
        vm.stopPrank();
    }

    function test_CloseFactorCapsRepayDuringLiquidation() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 75 / 100);

        _setUnderlyingPrice(0.7e18);
        assertLt(_healthFactor(alice), 1e18, "now liquidatable");

        uint256 debtBefore = _debtOf(alice);
        uint256 expectedMaxRepay = debtBefore * 50 / 100; // CLOSE_FACTOR = 50%

        vm.prank(liquidator);
        lending.liquidate(alice, address(vault), type(uint256).max);

        uint256 debtAfter = _debtOf(alice);
        uint256 actualRepaid = debtBefore - debtAfter;

        assertLe(actualRepaid, expectedMaxRepay + 2, "must respect close factor");
    }

    function test_LiquidationDoesNotCreateAssetsOutOfThinAir() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);
        assertGt(shares, 0);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 75 / 100);
        _setUnderlyingPrice(0.7e18);

        uint256 poolCashBefore = _poolCash();
        uint256 liqStableBefore = stable.balanceOf(liquidator);
        uint256 totalDebtBefore = _totalDebt();

        vm.prank(liquidator);
        lending.liquidate(alice, address(vault), type(uint256).max);

        uint256 poolCashAfter = _poolCash();
        uint256 liqStableAfter = stable.balanceOf(liquidator);
        uint256 totalDebtAfter = _totalDebt();

        assertLe(totalDebtAfter, totalDebtBefore, "debt should not increase");
        assertEq(
            poolCashAfter,
            poolCashBefore + (liqStableBefore - liqStableAfter),
            "pool cash should only increase by liquidator repayment"
        );
    }

    // ============================================================
    // 4. rounding / dust / edge cases
    // ============================================================

    function test_SmallDonationStillDoesNotChangePoolCash() public {
        _mintVaultPositionAndPostCollateral(alice, 100e18);

        uint256 poolCashBefore = _poolCash();
        uint256 totalDebtBefore = _totalDebt();

        _donateToVault(1); // 1 wei

        assertEq(_poolCash(), poolCashBefore, "tiny donation can't change pool cash");
        assertEq(_totalDebt(), totalDebtBefore, "tiny donation can't change debt");
    }

    function test_SmallRepayDoesNotIncreaseDebt() public {
        _mintVaultPositionAndPostCollateral(alice, 1_000e18);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 40 / 100);

        uint256 debtBefore = _debtOf(alice);
        _repay(alice, 1); // 1 wei
        uint256 debtAfter = _debtOf(alice);

        assertLe(debtAfter, debtBefore, "small repay should never increase debt");
    }

    function test_PreviewRedeemMatchesActualRedeemWithinRounding() public {
        uint256 shares = _depositIntoVault(alice, 1_000e18);

        uint256 previewAssets = vault.previewRedeem(shares / 3);

        uint256 balBefore = asset.balanceOf(alice);
        vm.prank(alice);
        uint256 actualAssets = vault.redeem(shares / 3, alice, alice);
        uint256 balAfter = asset.balanceOf(alice);

        assertEq(actualAssets, balAfter - balBefore, "balance delta mismatch");
        assertApproxEqAbs(actualAssets, previewAssets, 2, "preview vs actual rounding mismatch");
    }

    function test_WithdrawCollateralShouldRevertIfItBreaksHF() public {
        uint256 shares = _mintVaultPositionAndPostCollateral(alice, 1_000e18);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 60 / 100);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt.NotHealthy.selector);
        lending.withdrawCollateral(address(vault), shares / 2);
        vm.stopPrank();
    }

    // ============================================================
    // 5. cross-module snapshots
    // ============================================================

    function test_Snapshot_DonationTransmissionPath() public {
        _mintVaultPositionAndPostCollateral(alice, 1_000e18);

        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = _sharePrice();
        uint256 collateralBefore = _collateralValue(alice);
        uint256 hfBefore = _healthFactor(alice);
        uint256 poolCashBefore = _poolCash();
        uint256 debtBefore = _totalDebt();

        _donateToVault(250e18);

        uint256 vaultAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = _sharePrice();
        uint256 collateralAfter = _collateralValue(alice);
        uint256 hfAfter = _healthFactor(alice);
        uint256 poolCashAfter = _poolCash();
        uint256 debtAfter = _totalDebt();

        assertGt(vaultAssetsAfter, vaultAssetsBefore, "vault assets up");
        assertGt(sharePriceAfter, sharePriceBefore, "share price up");
        assertGt(collateralAfter, collateralBefore, "collateral value up");
        assertGe(hfAfter, hfBefore, "HF same or better");
        assertEq(poolCashAfter, poolCashBefore, "pool cash unchanged");
        assertEq(debtAfter, debtBefore, "debt unchanged");
    }

    function test_Snapshot_LossTransmissionPath() public {
        _depositIntoVault(alice, 1_000e18);
        _investAllVaultCash();

        uint256 shares = vault.balanceOf(alice);
        _depositCollateralFromVaultShares(alice, shares);

        uint256 collateralBefore = _collateralValue(alice);
        _borrow(alice, collateralBefore * 50 / 100);

        uint256 vaultAssetsBefore = vault.totalAssets();
        uint256 sharePriceBefore = _sharePrice();
        uint256 hfBefore = _healthFactor(alice);
        uint256 poolCashBefore = _poolCash();
        uint256 debtBefore = _totalDebt();

        _simulateStrategyLoss(300e18);

        uint256 vaultAssetsAfter = vault.totalAssets();
        uint256 sharePriceAfter = _sharePrice();
        uint256 hfAfter = _healthFactor(alice);
        uint256 poolCashAfter = _poolCash();
        uint256 debtAfter = _totalDebt();

        assertLt(vaultAssetsAfter, vaultAssetsBefore, "vault assets down");
        assertLt(sharePriceAfter, sharePriceBefore, "share price down");
        assertLt(hfAfter, hfBefore, "HF down");
        assertEq(poolCashAfter, poolCashBefore, "pool cash unchanged");
        assertEq(debtAfter, debtBefore, "debt unchanged");
    }

    // ============================================================
    // 6. invariant-like tests
    // ============================================================

    function testInvariantLike_VaultTotalAssetsEqualsCashPlusStrategyAssets() public {
        _depositIntoVault(alice, 1_000e18);
        _investAllVaultCash();
        _simulateStrategyProfit(200e18);

        uint256 cashAssets = asset.balanceOf(address(vault));
        uint256 strategyAssets = strategy.totalAssets();
        uint256 totalAssets = vault.totalAssets();

        assertEq(totalAssets, cashAssets + strategyAssets, "vault accounting mismatch");
    }

    function testInvariantLike_ShareOracleDoesNotOverestimateRedeemValue() public {
        uint256 shares = _depositIntoVault(alice, 1_000e18);
        _donateToVault(333e18);

        uint256 oracleValue = (shares * _sharePrice()) / WAD;

        uint256 redeemableAssets = vault.previewRedeem(shares);
        uint256 underlyingPrice = baseOracle.price(address(asset));
        uint256 theoreticalValue = (redeemableAssets * underlyingPrice) / WAD;

        assertLe(oracleValue, theoreticalValue, "share oracle should not overestimate");
    }

    function testInvariantLike_SharePriceMovesDoNotDirectlyRewritePoolDebt() public {
        _mintVaultPositionAndPostCollateral(alice, 1_000e18);

        uint256 poolCashBefore = _poolCash();
        uint256 totalDebtBefore = _totalDebt();

        _donateToVault(200e18);
        _setUnderlyingPrice(1.2e18);

        assertEq(_poolCash(), poolCashBefore, "share/oracle move can't change pool cash directly");
        assertEq(_totalDebt(), totalDebtBefore, "share/oracle move can't change pool debt directly");
    }
}
