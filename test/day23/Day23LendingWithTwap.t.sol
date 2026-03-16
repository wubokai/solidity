// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";

import "../../src/day23/MiniAMM.sol";
import "../../src/day23/SimpleTWAPOracle.sol";
import "../../src/day23/AmmTwapAdapter.sol";
import "../../src/day23/LendingHarness.sol";
import "./MockERC20.sol";

contract Day23LendingWithTwapTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant PERIOD = 30 minutes;

    MockERC20 internal tokenA;
    MockERC20 internal stable;

    MiniAMM internal amm;
    SimpleTWAPOracle internal twap;
    AmmTwapAdapter internal adapter;
    LendingHarness internal lending;

    address internal lp = address(0xA11CE);
    address internal user = address(0xB0B);
    address internal attacker = address(0xBAD);

    function setUp() external {
        tokenA = new MockERC20("TokenA", "TKA");
        stable = new MockERC20("Stable", "USD");

        amm = new MiniAMM(IERC20Like(address(tokenA)), IERC20Like(address(stable)));
        twap = new SimpleTWAPOracle(address(amm), PERIOD);
        adapter = new AmmTwapAdapter(address(twap), address(tokenA), address(stable));

        lending = new LendingHarness(
            address(tokenA),
            address(stable),
            address(adapter),
            5000, // collateral factor = 50%
            8000  // liquidation threshold = 80%
        );

        // mint balances
        tokenA.mint(lp, 1_000_000 * WAD);
        stable.mint(lp, 1_000_000 * WAD);

        tokenA.mint(user, 1_000 * WAD);
        stable.mint(address(lending), 1_000_000 * WAD);

        tokenA.mint(attacker, 1_000_000 * WAD);
        stable.mint(attacker, 1_000_000 * WAD);

        // initial pool: 100 TokenA : 1000 Stable => 1 TokenA = 10 Stable
        vm.startPrank(lp);
        tokenA.approve(address(amm), type(uint256).max);
        stable.approve(address(amm), type(uint256).max);

        amm.addLiquidity(
            lp,
            100 * WAD,
            1_000 * WAD,
            100 * WAD,
            1_000 * WAD,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        // seed initial TWAP
        vm.warp(block.timestamp + PERIOD);
        twap.update();
    }

    function testInitialTwapPriceIsAbout10() external {
        uint256 px = adapter.getBasePrice();
        assertApproxEqAbs(px, 10 * WAD, 1e14);
    }

    function testDepositCollateralAndBorrow() external {
        vm.startPrank(user);
        tokenA.approve(address(lending), type(uint256).max);
        lending.depositCollateral(10 * WAD);

        uint256 collateralValue = lending.collateralValue(user);
        uint256 maxBorrow_ = lending.maxBorrow(user);
        uint256 hfBefore = lending.healthFactor(user);

        // 10 TokenA * 10 Stable = 100 Stable collateral value
        assertApproxEqAbs(collateralValue, 100 * WAD, 1e14);

        // 50% collateral factor => 50 Stable max borrow
        assertApproxEqAbs(maxBorrow_, 50 * WAD, 1e14);
        assertEq(hfBefore, type(uint256).max);

        lending.borrow(40 * WAD);

        uint256 hfAfter = lending.healthFactor(user);
        assertGt(hfAfter, 1e18); // still healthy
        vm.stopPrank();
    }

    function testShortManipulationDoesNotImmediatelyChangeBorrowPower() external {
        vm.startPrank(user);
        tokenA.approve(address(lending), type(uint256).max);
        lending.depositCollateral(10 * WAD);

        uint256 beforeBorrowPower = lending.maxBorrow(user);
        vm.stopPrank();

        // attack: use Stable to buy TokenA -> tokenA spot price in stable goes up
        vm.startPrank(attacker);
        stable.approve(address(amm), type(uint256).max);
        amm.swap1For0(
            500 * WAD,
            0,
            attacker,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        // less than PERIOD => oracle update should revert, so lending still sees old TWAP
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(SimpleTWAPOracle.PeriodNotElapsed.selector);
        twap.update();

        uint256 afterBorrowPower = lending.maxBorrow(user);

        // still old TWAP-based borrow power
        assertApproxEqAbs(afterBorrowPower, beforeBorrowPower, 1e14);
    }

    function testSustainedManipulationRaisesTwapAndBorrowPower() external {
        vm.startPrank(user);
        tokenA.approve(address(lending), type(uint256).max);
        lending.depositCollateral(10 * WAD);
        uint256 beforeBorrowPower = lending.maxBorrow(user);
        vm.stopPrank();

        // push tokenA price up by buying tokenA with stable
        vm.startPrank(attacker);
        stable.approve(address(amm), type(uint256).max);
        amm.swap1For0(
            500 * WAD,
            0,
            attacker,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        // keep manipulated reserves for an entire TWAP period
        vm.warp(block.timestamp + PERIOD);
        twap.update();

        uint256 newPrice = adapter.getBasePrice();
        uint256 afterBorrowPower = lending.maxBorrow(user);

        assertGt(newPrice, 10 * WAD);
        assertGt(afterBorrowPower, beforeBorrowPower);
    }

}