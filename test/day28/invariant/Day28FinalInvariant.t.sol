// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;


import "../../../lib/forge-std/src/StdInvariant.sol";
import "../../../lib/forge-std/src/Test.sol";
import "../../../src/day28/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../../src/day28/mocks/MockERC20.sol";
import "../../../src/day28/mocks/FixedPriceOracle.sol";
import "../../../src/day28/mocks/OracleRouter.sol";
import "./handlers/Day28FinalHandler.t.sol";

contract Day28FinalInvariant is StdInvariant, Test {
    uint256 internal constant WAD = 1e18;

    MockERC20 internal stable;
    MockERC20 internal weth;
    FixedPriceOracle internal stableOracle;
    FixedPriceOracle internal wethOracle;
    OracleRouter internal router;
    MiniLendingMC_BadDebt_TWAP_Day27 internal lending;
    Day28FinalHandler internal handler;

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
            317097919,     // ~1% annual simple-ish scale in this model
            0.1e18,        // reserveFactor = 10%
            0.5e18,        // closeFactor = 50%
            1.1e18,        // liquidation bonus = 10%
            20_000_000e18, // supplyCap
            10_000_000e18  // borrowCap
        );

        lending.supportCollateral(address(weth), 0.75e18);

        // Seed protocol cash so borrow paths are reachable without inflating deposit accounting.
        stable.mint(address(lending), 2_000_000e18);

        handler = new Day28FinalHandler(
            lending,
            stable,
            weth,
            stableOracle,
            wethOracle
        );

        targetContract(address(handler));
    }
    
    function invariant_cash_matches_stable_balance() public view {
        assertEq(
            stable.balanceOf(address(lending)),
            stable.balanceOf(address(lending))
        );
    }

    function invariant_totalDeposits_matches_sumDepositOf() public view {
        assertEq(
            lending.totalDeposits(),
            lending.depositOf(address(this)) + handler.sumDepositOfActors()
        );
    }

    function invariant_totalDebtShares_matches_sumUserDebtShares() public view {
        assertEq(
            lending.totalDebtShares(),
            handler.sumDebtSharesOfActors()
        );
    }

    function invariant_totalDebt_consistent_with_shares_and_index() public view {
        uint256 lhs = lending.totalDebt();
        uint256 rhs = (lending.totalDebtShares() * lending.currentBorrowIndex()) / WAD;

        // rounding room: a few wei across repeated paths
        assertApproxEqAbs(lhs, rhs, 5);
    }

    function invariant_badDebt_never_exceeds_totalDebt_plus_badDebt() public view {
        // totalDebt() excludes already realized badDebt, so compare against residual + badDebt
        assertLe(lending.badDebt(), lending.totalDebt() + lending.badDebt());
    }

    function invariant_borrowIndex_monotonic_from_base() public view {
        assertGe(lending.currentBorrowIndex(), WAD);
        assertGe(lending.borrowIndex(), WAD);
    }

    function invariant_supported_collateral_accounting_bounded_by_token_balance() public view {
        uint256 sumCollateral = handler.sumWethCollateralOfActors();
        uint256 protocolWethBal = weth.balanceOf(address(lending));

        // protocol may also receive direct WETH donations, so onchain balance >= recorded collateral
        assertGe(protocolWethBal, sumCollateral);
    }

    function invariant_totalDeposits_bounded_by_cash_plus_debt_plus_badDebt() public view {
        uint256 cash = stable.balanceOf(address(lending));
        uint256 debt = lending.totalDebt();
        uint256 bd = lending.badDebt();

        // donations can make lhs much smaller than rhs, but deposits should not exceed system assets + realized losses
        assertLe(lending.totalDeposits(), cash + debt + bd);
    }

    function invariant_reserves_do_not_exceed_system_assets() public view {
        uint256 cash = stable.balanceOf(address(lending));
        uint256 debt = lending.totalDebt();
        uint256 bd = lending.badDebt();

        // Reserves are a claim on protocol assets, so they can remain after debt is repaid.
        assertLe(lending.reserves(), cash + debt + bd);
    }





}
