// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day27/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../src/day27/mocks/MockERC20.sol";
import "../../src/day27/mocks/FixedPriceOracle.sol";
import "../../src/day27/mocks/OracleRouter.sol";

contract Day27HardeningTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal stable;
    MockERC20 internal weth;
    MockERC20 internal wbtc;

    FixedPriceOracle internal oracle;
    OracleRouter internal router;
    MiniLendingMC_BadDebt_TWAP_Day27 internal lending;

    address internal owner = address(this);
    address internal lp = address(11);
    address internal alice = address(12);
    address internal bob = address(13);
    address internal liquidator = address(14);

    function setUp() public {
        stable = new MockERC20("Mock USD","USD");
        weth = new MockERC20("Wrapped Ether", "WETH");
        wbtc = new MockERC20("Wrapped BTC", "WBTC");

        oracle = new FixedPriceOracle();
        router = new OracleRouter();

        oracle.setPrice(address(stable), 1e18);
        oracle.setPrice(address(weth), 2000e18);
        oracle.setPrice(address(wbtc), 30000e18);

        router.setOracle(address(stable), address(oracle));
        router.setOracle(address(weth), address(oracle));
        router.setOracle(address(wbtc), address(oracle));

        lending = new MiniLendingMC_BadDebt_TWAP_Day27(
            address(stable),
            address(router),
            0,          // ratePerSecond
            0.1e18,     // reserveFactor
            0.5e18,     // closeFactor
            1.05e18,    // liquidationBonus
            1_000_000e18, // supplyCap
            500_000e18    // borrowCap

        );

        lending.supportedCollateral(address(weth), 0.8e18);
        lending.supportedCollateral(address(wbtc), 0.75e18);

        stable.mint(lp, 1_000_000e18);
        stable.mint(alice, 1_000_000e18);
        stable.mint(bob, 1_000_000e18);
        stable.mint(liquidator, 1_000_000e18);

        weth.mint(alice, 100e18);
        weth.mint(bob, 100e18);
        weth.mint(liquidator, 100e18);

        wbtc.mint(alice, 10e18);
        wbtc.mint(bob, 10e18);
        wbtc.mint(liquidator, 10e18);

        vm.startPrank(lp);
        stable.approve(address(lending), type(uint256).max);
        lending.deposit(300_000e18);
        vm.stopPrank();

        vm.startPrank(alice);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        wbtc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        wbtc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        wbtc.approve(address(lending), type(uint256).max);
        vm.stopPrank();


    }

    // -------------------------
    // config sanity
    // -------------------------

    function test_setReserveFactor_revertsAbove1e18() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidConfig.selector);
        lending.setReserveFactor(1e18 + 1);
    }

    function test_setCloseFactor_revertsWhenZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidConfig.selector);
        lending.setCloseFactor(0);
    }

    function test_setCloseFactor_revertsAbove1e18() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidConfig.selector);
        lending.setCloseFactor(1e18 + 1);
    }

    function test_setLiquidationBonus_revertsBelow1x() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidConfig.selector);
        lending.setLiquidationBonus(0.99e18);
    }

    function test_setLiquidationBonus_revertsTooHigh() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidConfig.selector);
        lending.setLiquidationBonus(1.200000000000000001e18);
    }

    function test_setOracleRouter_revertsZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.InvalidOracleRouter.selector);
        lending.setOracleRouter(address(0));
    }

    // -------------------------
    // pause matrix
    // -------------------------

    function test_pause_blocksDeposit() public {
        lending.pause();

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.PausedErr.selector);
        lending.deposit(100e18);
        vm.stopPrank();
    }

    function test_pause_blocksWithdraw() public {
        vm.startPrank(alice);
        lending.deposit(100e18);
        vm.stopPrank();


        lending.pause();

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.PausedErr.selector);
        lending.withdraw(100e18);
        vm.stopPrank();
    }

    function test_pause_blocksDepositCollateral() public {
        lending.pause();

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.PausedErr.selector);
        lending.depositCollateral(address(weth), 1e18);
        vm.stopPrank();
    }

    function test_pause_blocksWithdrawCollateral() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        vm.stopPrank();

        lending.pause();

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.PausedErr.selector);
        lending.withdrawCollateral(address(weth), 1e18);
        vm.stopPrank();
    }

    function test_pause_blocksBorrow() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        vm.stopPrank();

        lending.pause();

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.PausedErr.selector);
        lending.borrow(100e18);
        vm.stopPrank();
    }

    function test_pause_allowsRepay() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(500e18);
        vm.stopPrank();

        lending.pause();

        uint256 debtBefore = lending.debtOf(alice);

        vm.prank(alice);
        lending.repay(100e18);

        uint256 debtAfter = lending.debtOf(alice);
        assertLt(debtAfter, debtBefore);
    }

    function test_pause_allowsLiquidate() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18); // value 2000, borrowable 1600
        lending.borrow(1500e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 1000e18); // borrowable becomes 800 => unhealthy
        lending.pause();

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), 300e18);

        uint256 liquidatorWethAfter = weth.balanceOf(liquidator);
        assertGt(liquidatorWethAfter, liquidatorWethBefore);
    }

    // -------------------------
    // supplyCap / borrowCap reach + release
    // -------------------------

    function test_supplyCap_reachThenWithdrawThenDepositAgain() public {
        lending.setSupplyCap(300_100e18); // currently 300_000e18 already by lp

        vm.startPrank(alice);
        lending.deposit(100e18);

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.SupplyCapExceeded.selector);
        lending.deposit(1);
        vm.stopPrank();

        vm.startPrank(alice);
        lending.withdraw(50e18);
        lending.deposit(50e18); // reopened space
        vm.stopPrank();
    }

    function test_borrowCap_reachThenRepayThenBorrowAgain() public {
        lending.setBorrowCap(1000e18);

        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1000e18);

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.BorrowCapExceeded.selector);
        lending.borrow(1e18);

        lending.repay(400e18);
        lending.borrow(400e18); // reopened after repay
        vm.stopPrank();
    }

    // -------------------------
    // governance changes affect risk layer, not nominal accounting
    // -------------------------

    function test_setCollateralFactor_changesHF_notNominalAmounts() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1000e18);
        vm.stopPrank();

        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 userCollateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 cashBefore = stable.balanceOf(address(lending));

        uint256 hfBefore = lending.healthFactor(alice);

        lending.setCollateralFactor(address(weth), 0.6e18);

        uint256 hfAfter = lending.healthFactor(alice);

        assertLt(hfAfter, hfBefore);

        assertEq(lending.debtSharesOf(alice), debtSharesBefore);
        assertEq(lending.totalDebtShares(), totalDebtSharesBefore);
        assertEq(lending.collateralBalanceOf(alice, address(weth)), userCollateralBefore);
        assertEq(stable.balanceOf(address(lending)), cashBefore);
    }

    function test_oraclePriceChange_changesHF_notNominalAmounts() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1000e18);
        vm.stopPrank();

        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 userCollateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 cashBefore = stable.balanceOf(address(lending));

        uint256 hfBefore = lending.healthFactor(alice);

        oracle.setPrice(address(weth), 1500e18);

        uint256 hfAfter = lending.healthFactor(alice);

        assertLt(hfAfter, hfBefore);

        assertEq(lending.debtSharesOf(alice), debtSharesBefore);
        assertEq(lending.totalDebtShares(), totalDebtSharesBefore);
        assertEq(lending.collateralBalanceOf(alice, address(weth)), userCollateralBefore);
        assertEq(stable.balanceOf(address(lending)), cashBefore);
    }

    function test_setBorrowCap_affectsFutureBorrow_notExistingNominalState() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(500e18);
        vm.stopPrank();

        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 cashBefore = stable.balanceOf(address(lending));

        lending.setBorrowCap(500e18);

        assertEq(lending.debtSharesOf(alice), debtSharesBefore);
        assertEq(lending.totalDebtShares(), totalDebtSharesBefore);
        assertEq(stable.balanceOf(address(lending)), cashBefore);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.BorrowCapExceeded.selector);
        lending.borrow(1e18);
        vm.stopPrank();
    }

    // -------------------------
    // liquidation / bad debt path sanity
    // -------------------------

    function test_liquidation_backsolve_whenCollateralInsufficient() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        lending.borrow(1500e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 500e18); // deeply underwater

        uint256 liqStableBefore = stable.balanceOf(liquidator);
        uint256 liqWethBefore = weth.balanceOf(liquidator);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), 750e18); // attempt

        uint256 liqStableAfter = stable.balanceOf(liquidator);
        uint256 liqWethAfter = weth.balanceOf(liquidator);

        assertGt(liqWethAfter, liqWethBefore);
        assertLt(liqStableAfter, liqStableBefore);
    }
    

     function test_realizeBadDebt_whenNoCollateralLeft() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        lending.borrow(1500e18);
        vm.stopPrank();

        oracle.setPrice(address(weth), 500e18);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), 750e18);

        // if collateral exhausted and debt remains, contract realizes bad debt
        if (lending.collateralValue(alice) == 0) {
            assertGt(lending.badDebt(), 0);
        }
    }


}