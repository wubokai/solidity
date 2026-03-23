// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../lib/forge-std/src/Test.sol";

import "../../../src/day28/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../../src/day28/mocks/MockERC20.sol";
import "../../../src/day28/mocks/FixedPriceOracle.sol";
import "../../../src/day28/mocks/OracleRouter.sol";

contract Day28PauseCapBehaviorTest is Test {
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
            20_000e18, // smaller caps for testing
            8_000e18
        );

        lending.supportCollateral(address(weth), 0.75e18);

        // Seed pool cash without consuming user-facing supply cap accounting.
        stable.mint(address(lending), 50_000e18);

        stable.mint(alice, 50_000e18);
        weth.mint(alice, 50e18);
        stable.mint(bob, 50_000e18);
        weth.mint(bob, 50e18);

        vm.startPrank(alice);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(bob);
        stable.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    function test_pause_blocks_risk_expansion_but_allows_repay_and_liquidate() public {
        vm.startPrank(alice);
        lending.deposit(2000e18);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1500e18);
        vm.stopPrank();

        wethOracle.setPrice(address(weth), 700e18);
        lending.pause();

        vm.startPrank(alice);

        vm.expectRevert();
        lending.deposit(100e18);

        vm.expectRevert();
        lending.withdraw(100e18);

        vm.expectRevert();
        lending.depositCollateral(address(weth), 1e18);

        vm.expectRevert();
        lending.withdrawCollateral(address(weth), 0.1e18);

        vm.expectRevert();
        lending.borrow(100e18);

        lending.repay(300e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lending.liquidate(alice, address(weth), 300e18);
        vm.stopPrank();
    }

    function test_supply_cap_reach_and_release() public {
        vm.startPrank(alice);
        lending.deposit(20_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.SupplyCapExceeded.selector);
        lending.deposit(1e18);
        vm.stopPrank();

        vm.startPrank(alice);
        lending.withdraw(1000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lending.deposit(500e18);
        vm.stopPrank();
    }

    function test_borrow_cap_reach_and_release() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 10e18);
        lending.borrow(8_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lending.depositCollateral(address(weth), 10e18);

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP_Day27.BorrowCapExceeded.selector);
        lending.borrow(1e18);
        vm.stopPrank();

        vm.startPrank(alice);
        lending.repay(2_000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        lending.borrow(500e18);
        vm.stopPrank();
    }

    function test_governance_config_change_does_not_directly_mutate_nominal_accounting() public {
        vm.startPrank(alice);
        lending.deposit(2000e18);
        lending.depositCollateral(address(weth), 5e18);
        lending.borrow(2000e18);
        vm.stopPrank();

        uint256 depositBefore = lending.depositOf(alice);
        uint256 collateralBefore = lending.collateralBalanceOf(alice, address(weth));
        uint256 debtSharesBefore = lending.debtSharesOf(alice);
        uint256 totalDebtSharesBefore = lending.totalDebtShares();
        uint256 cashBefore = stable.balanceOf(address(lending));

        lending.setBorrowCap(20_000e18);
        lending.setSupplyCap(30_000e18);
        lending.setCloseFactor(0.4e18);
        lending.setLiquidationBonus(1.05e18);

        assertEq(lending.depositOf(alice), depositBefore);
        assertEq(lending.collateralBalanceOf(alice, address(weth)), collateralBefore);
        assertEq(lending.debtSharesOf(alice), debtSharesBefore);
        assertEq(lending.totalDebtShares(), totalDebtSharesBefore);
        assertEq(stable.balanceOf(address(lending)), cashBefore);
    }
}
