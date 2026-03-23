// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../lib/forge-std/src/Test.sol";

import "../../../src/day28/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../../src/day28/mocks/MockERC20.sol";
import "../../../src/day28/mocks/FixedPriceOracle.sol";
import "../../../src/day28/mocks/OracleRouter.sol";
contract Day28RiskSeparationTest is Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal stable;
    MockERC20 internal weth;
    FixedPriceOracle internal stableOracle;
    FixedPriceOracle internal wethOracle;
    OracleRouter internal router;
    MiniLendingMC_BadDebt_TWAP_Day27 internal lending;

    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        stable = new MockERC20("Stable", "STBL");
        weth = new MockERC20("Wrapped ETH", "WETH");

        stableOracle = new FixedPriceOracle();
        wethOracle = new FixedPriceOracle();
        router = new OracleRouter();

        stableOracle.setPrice(address(stable), 1e18);
        wethOracle.setPrice(address(weth), 2000e18);

        router.setOracle(address(stable), address(stableOracle));
        router.setOracle(address(weth), address(wethOracle));

        lending = new MiniLendingMC_BadDebt_TWAP_Day27(
            address(stable),
            address(router),
            317097919,
            0.1e18,
            0.5e18,
            1.1e18,
            10_000_000e18,
            5_000_000e18
        );

        lending.supportCollateral(address(weth), 0.75e18);

        stable.mint(address(this), 2_000_000e18);
        stable.approve(address(lending), type(uint256).max);
        lending.deposit(1_000_000e18);

        stable.mint(alice, 100_000e18);
        weth.mint(alice, 100e18);
        stable.mint(bob, 100_000e18);
        weth.mint(bob, 100e18);

        vm.startPrank(alice);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function test_oracle_price_drop_changes_risk_not_nominal_balances() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(8_000e18);
        vm.stopPrank();

        uint256 collateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 cashBefore = stable.balanceOf(address(lending));
        uint256 hfBefore = lending.healthFactor(alice);

        wethOracle.setPrice(address(weth), 1200e18);

        uint256 collateralAfter = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesAfter = lending.debtSharesOf(alice);
        uint256 totalDebtSharesAfter = lending.totalDebtShares();
        uint256 cashAfter = stable.balanceOf(address(lending));
        uint256 hfAfter = lending.healthFactor(alice);

        assertEq(collateralAfter, collateralBefore);
        assertEq(debtSharesAfter, debtSharesBefore);
        assertEq(totalDebtSharesAfter, totalDebtSharesBefore);
        assertEq(cashAfter, cashBefore);

        assertLt(hfAfter, hfBefore);
    }

    function test_collateral_factor_change_changes_borrow_power_not_nominal_balances() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(6_000e18);
        vm.stopPrank();

        uint256 collateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 cashBefore = stable.balanceOf(address(lending));
        uint256 hfBefore = lending.healthFactor(alice);
        uint256 maxBorrowableBefore = lending.maxBorrowable(alice);

        lending.setCollateralFactor(address(weth), 0.60e18);

        uint256 collateralAfter = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesAfter = lending.debtSharesOf(alice);
        uint256 totalDebtSharesAfter = lending.totalDebtShares();
        uint256 cashAfter = stable.balanceOf(address(lending));
        uint256 hfAfter = lending.healthFactor(alice);
        uint256 maxBorrowableAfter = lending.maxBorrowable(alice);

        assertEq(collateralAfter, collateralBefore);
        assertEq(debtSharesAfter, debtSharesBefore);
        assertEq(totalDebtSharesAfter, totalDebtSharesBefore);
        assertEq(cashAfter, cashBefore);

        assertLt(hfAfter, hfBefore);
        assertLt(maxBorrowableAfter, maxBorrowableBefore);
    }

    function test_price_rise_changes_valuation_not_nominal_accounting() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 5e18);
        lending.borrow(2_000e18);
        vm.stopPrank();

        uint256 collateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 cashBefore = stable.balanceOf(address(lending));
        uint256 hfBefore = lending.healthFactor(alice);
        uint256 maxBorrowableBefore = lending.maxBorrowable(alice);

        wethOracle.setPrice(address(weth), 3000e18);

        assertEq(lending.collateralBalanceOf(alice, address(weth)), collateralBefore);
        assertEq(lending.debtSharesOf(alice), debtSharesBefore);
        assertEq(lending.totalDebtShares(), totalDebtSharesBefore);
        assertEq(stable.balanceOf(address(lending)), cashBefore);

        assertGt(lending.healthFactor(alice), hfBefore);
        assertGt(lending.maxBorrowable(alice), maxBorrowableBefore);
    }

    function test_liquidation_changes_target_state_but_not_other_user_nominal_deposits() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(2000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lending.deposit(5000e18);
        vm.stopPrank();

        uint256 bobDepositBefore = lending.depositOf(bob);
        uint256 poolCashBefore = stable.balanceOf(address(lending));

        wethOracle.setPrice(address(weth), 900e18);

        vm.startPrank(bob);
        lending.liquidate(alice, address(weth), 1000e18);
        vm.stopPrank();

        assertEq(lending.depositOf(bob), bobDepositBefore);
        assertLe(stable.balanceOf(address(lending)), poolCashBefore + 1000e18);
    }
}