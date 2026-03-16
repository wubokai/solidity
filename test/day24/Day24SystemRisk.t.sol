// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";

import {MiniAMM, IERC20Like} from "../../src/day24/MiniAMM.sol";
import {SimpleTWAPOracle} from "../../src/day24/SimpleTWAPOracle.sol";
import {AmmTwapAdapter} from "../../src/day24/AmmTwapAdapter.sol";
import {OracleRouter} from "../../src/day24/OracleRouter.sol";
import {MiniLendingMC_BadDebt_TWAP} from "../../src/day24/MiniLendingMC_BadDebt_TWAP.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOWANCE");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "BALANCE");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FixedPriceOracle {
    mapping(address => uint256) public priceOf;

    function setPrice(address asset, uint256 price) external {
        priceOf[asset] = price;
    }

    function getPrice(address asset) external view returns (uint256) {
        uint256 p = priceOf[asset];
        require(p != 0, "NO_PRICE");
        return p;
    }
}

contract Day24SystemRiskTest is Test {
    uint256 internal constant WAD = 1e18;
    uint32 internal constant TWAP_PERIOD = 1 hours;

    MockERC20 internal weth;
    MockERC20 internal usdc;

    MiniAMM internal amm;
    SimpleTWAPOracle internal twap;
    AmmTwapAdapter internal adapter;
    OracleRouter internal router;
    MiniLendingMC_BadDebt_TWAP internal lending;

    FixedPriceOracle internal fixedOracle;

    address internal lp = address(0x1111);
    address internal alice = address(0x2222);
    address internal attacker = address(0x3333);
    address internal liquidator = address(0x4444);

    function setUp() public {
        weth = new MockERC20("Wrapped Ether", "WETH");
        usdc = new MockERC20("USD Coin", "USDC");

        amm = new MiniAMM(IERC20Like(address(weth)), IERC20Like(address(usdc)));
        twap = new SimpleTWAPOracle(address(amm), TWAP_PERIOD);
        adapter = new AmmTwapAdapter(address(twap), address(weth), address(usdc));

        router = new OracleRouter();
        fixedOracle = new FixedPriceOracle();

        lending = new MiniLendingMC_BadDebt_TWAP(
            address(usdc),
            address(router),
            0, // ratePerSecond
            0  // reserveFactor
        );

        lending.listCollateral(address(weth), true);

        // Initial fixed prices
        fixedOracle.setPrice(address(weth), 2000e18);
        fixedOracle.setPrice(address(usdc), 1e18);

        router.setOracle(address(weth), address(fixedOracle));
        router.setOracle(address(usdc), address(fixedOracle));

        // Seed balances
        weth.mint(lp, 1_000e18);
        usdc.mint(lp, 10_000_000e18);

        weth.mint(alice, 100e18);
        usdc.mint(alice, 1_000_000e18);

        weth.mint(attacker, 2_000e18);
        usdc.mint(attacker, 20_000_000e18);

        weth.mint(liquidator, 100e18);
        usdc.mint(liquidator, 20_000_000e18);

        // Approvals
        vm.startPrank(lp);
        weth.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(alice);
        weth.approve(address(lending), type(uint256).max);
        usdc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        weth.approve(address(amm), type(uint256).max);
        usdc.approve(address(amm), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(liquidator);
        usdc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        // Build AMM at 2000 USDC / WETH
        vm.prank(lp);
        amm.addLiquidity(
            lp,
            100e18,      // amount0D = 100 WETH
            200_000e18,  // amount1D = 200k USDC
            0,
            0,
            block.timestamp + 1 days
        );

        // Deposit lending liquidity through real deposit path
        vm.prank(lp);
        lending.deposit(2_000_000e18);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _warmUpTwap() internal {
        // Your SimpleTWAPOracle starts with price0Average = 0.
        // Need one full period + update before adapter returns real price.
        vm.warp(block.timestamp + TWAP_PERIOD + 1);
        twap.update();
    }

    function _switchRouterToTwap() internal {
        router.setOracle(address(weth), address(adapter));
        // keep USDC on fixed oracle = 1e18
        router.setOracle(address(usdc), address(fixedOracle));
    }

    function _aliceDepositCollateral(uint256 amount) internal {
        vm.prank(alice);
        lending.depositCollateral(address(weth), amount);
    }

    function _aliceDepositAndBorrow(uint256 collateralAmount, uint256 borrowAmount) internal {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), collateralAmount);
        lending.borrow(borrowAmount);
        vm.stopPrank();
    }

    function _attackerPumpPrice() internal returns (uint256 spotAfter) {
        // Buy WETH using lots of USDC => WETH price up
        vm.prank(attacker);
        amm.swap1For0(
            500_000e18,
            0,
            attacker,
            block.timestamp + 1 days
        );
        return _spotPrice();
    }

    function _attackerDumpPrice() internal returns (uint256 spotAfter) {
        // Sell lots of WETH => WETH price down
        vm.prank(attacker);
        amm.swap0For1(
            300e18,
            0,
            attacker,
            block.timestamp + 1 days
        );
        spotAfter = _spotPrice();
    }

    function _spotPrice() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = amm.getReserves();
        return uint256(r1) * 1e18 / uint256(r0); // token1 per token0
    }

    function _updateTwapAfterPeriod() internal {
        vm.warp(block.timestamp + TWAP_PERIOD + 1);
        twap.update();
    }

    /*//////////////////////////////////////////////////////////////
                                TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TwapWarmup_AdapterReturnsInitialPriceAfterFirstUpdate() public {
        _warmUpTwap();
        _switchRouterToTwap();

        uint256 twapPrice = router.getPrice(address(weth));
        assertEq(twapPrice, 2000e18, "initial twap price should be 2000e18");
    }

    function test_ShortSpotManipulation_DoesNotImmediatelyIncreaseBorrowPower() public {
        _warmUpTwap();
        _switchRouterToTwap();

        _aliceDepositCollateral(10e18);

        uint256 beforeSpot = _spotPrice();
        uint256 beforeTwapPrice = router.getPrice(address(weth));
        uint256 beforeBorrowPower = lending.collateralValueUSD(alice) * 80e16 / 1e18; // just inspect value path? no borrow cap function

        _attackerPumpPrice();

        uint256 afterSpot = _spotPrice();
        uint256 afterTwapPrice = router.getPrice(address(weth));
        uint256 afterBorrowPower = lending.collateralValueUSD(alice) * 80e16 / 1e18;

        assertGt(afterSpot, beforeSpot, "spot should increase");
        assertEq(afterTwapPrice, beforeTwapPrice, "twap price should not move immediately");
        assertEq(afterBorrowPower, beforeBorrowPower, "collateral value through router should not jump immediately");
        assertGt(afterSpot, afterTwapPrice, "spot should exceed protocol price after short manipulation");
    }

    function test_SustainedManipulation_PropagatesThroughTwapToLending() public {
        _warmUpTwap();
        _switchRouterToTwap();

        _aliceDepositCollateral(10e18);

        uint256 beforeTwapPrice = router.getPrice(address(weth));
        uint256 beforeCollateralValue = lending.collateralValueUSD(alice);

        _attackerPumpPrice();
        _updateTwapAfterPeriod();

        uint256 afterTwapPrice = router.getPrice(address(weth));
        uint256 afterCollateralValue = lending.collateralValueUSD(alice);

        assertGt(afterTwapPrice, beforeTwapPrice, "twap should move higher after sustained manipulation");
        assertGt(afterCollateralValue, beforeCollateralValue, "collateral value should rise through lending router");
    }

    function test_TwapPriceDrop_CanTurnHealthyPositionLiquidatable() public {
        _warmUpTwap();
        _switchRouterToTwap();

        // 10 WETH * 2000 = 20,000 collateral value
        // adjusted at 80% => 16,000
        // borrow 12,000 => healthy
        _aliceDepositAndBorrow(10e18, 12_000e18);

        uint256 hfBefore = lending.healthFactor(alice);
        assertGt(hfBefore, 1e18, "position should start healthy");

        _attackerDumpPrice();
        _updateTwapAfterPeriod();

        uint256 twapPriceAfterDump = router.getPrice(address(weth));
        uint256 hfAfter = lending.healthFactor(alice);

        assertLt(twapPriceAfterDump, 2000e18, "twap price should be lower");
        assertLt(hfAfter, 1e18, "position should become liquidatable");

        uint256 liquidatorWethBefore = weth.balanceOf(liquidator);
        uint256 aliceDebtBefore = lending.debtOf(alice);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), aliceDebtBefore);

        uint256 liquidatorWethAfter = weth.balanceOf(liquidator);
        uint256 aliceDebtAfter = lending.debtOf(alice);

        assertGt(liquidatorWethAfter, liquidatorWethBefore, "liquidator should seize collateral");
        assertLt(aliceDebtAfter, aliceDebtBefore, "debt should be reduced after liquidation");
    }

    function test_TwapLag_SpotRecoveryDoesNotImmediatelyRestoreProtocolPrice() public {
        _warmUpTwap();
        _switchRouterToTwap();

        _aliceDepositCollateral(10e18);

        uint256 baseTwap = router.getPrice(address(weth));

        // Pump and let TWAP move up
        _attackerPumpPrice();
        _updateTwapAfterPeriod();

        uint256 pumpedTwap = router.getPrice(address(weth));
        assertGt(pumpedTwap, baseTwap, "twap should move up after sustained pump");

        // Immediately dump spot back down, but do not update TWAP yet
        _attackerDumpPrice();

        uint256 recoveredSpot = _spotPrice();
        uint256 staleTwap = router.getPrice(address(weth));

        assertLt(recoveredSpot, staleTwap, "spot can move down faster than twap");
        assertEq(staleTwap, pumpedTwap, "protocol still sees stale higher twap before next update");
    }

    function test_OracleRouter_SourceSwitch_PreservesUnifiedPricingFlow() public {
        _aliceDepositCollateral(10e18);

        uint256 fixedPrice = router.getPrice(address(weth));
        uint256 fixedCollateralValue = lending.collateralValueUSD(alice);

        assertEq(fixedPrice, 2000e18, "fixed price should start at 2000e18");
        assertEq(fixedCollateralValue, 20_000e18, "10 WETH should be worth 20,000e18 under fixed price");

        _warmUpTwap();
        _switchRouterToTwap();

        uint256 twapPrice0 = router.getPrice(address(weth));
        uint256 twapCollateralValue0 = lending.collateralValueUSD(alice);

        assertEq(twapPrice0, 2000e18, "twap should match initial spot after warm-up");
        assertEq(twapCollateralValue0, fixedCollateralValue, "router switch should preserve value under same price");

        _attackerPumpPrice();
        _updateTwapAfterPeriod();

        uint256 twapPrice1 = router.getPrice(address(weth));
        uint256 twapCollateralValue1 = lending.collateralValueUSD(alice);

        assertGt(twapPrice1, twapPrice0, "router should now read updated twap source");
        assertGt(twapCollateralValue1, twapCollateralValue0, "lending should reflect new source automatically");
    }

    function test_SeverePriceDrop_CanRealizeBadDebt() public {
        _warmUpTwap();
        _switchRouterToTwap();

        // Start slightly healthy
        _aliceDepositAndBorrow(10e18, 15_000e18);

        uint256 hfBefore = lending.healthFactor(alice);
        assertGt(hfBefore, 1e18, "should start healthy");

        _attackerDumpPrice();
        _updateTwapAfterPeriod();

        uint256 hfAfter = lending.healthFactor(alice);
        assertLt(hfAfter, 1e18, "should become unhealthy");

        uint256 badDebtBefore = lending.badDebt();
        uint256 debtBefore = lending.debtOf(alice);

        vm.prank(liquidator);
        lending.liquidate(alice, address(weth), debtBefore);

        uint256 badDebtAfter = lending.badDebt();
        uint256 debtAfter = lending.debtOf(alice);
        uint256 remainingCollateral = lending.collateralOf(alice, address(weth));

        assertEq(remainingCollateral, 0, "severe drop path should exhaust collateral");
        assertEq(debtAfter, 0, "remaining debt should be absorbed as bad debt when no collateral remains");
        assertGt(badDebtAfter, badDebtBefore, "bad debt should increase");
    }

    function test_Sanity_PriceMovementDoesNotDirectlyRewriteCashOrNominalDebt() public {
        _warmUpTwap();
        _switchRouterToTwap();

        _aliceDepositAndBorrow(10e18, 12_000e18);

        uint256 cashBefore = lending.cash();
        uint256 debtBefore = lending.debtOf(alice);
        uint256 totalDebtBefore = lending.totalDebt();

        _attackerPumpPrice();

        uint256 cashMid = lending.cash();
        uint256 debtMid = lending.debtOf(alice);
        uint256 totalDebtMid = lending.totalDebt();

        assertEq(cashMid, cashBefore, "spot manipulation should not change lending cash");
        assertEq(debtMid, debtBefore, "spot manipulation should not change nominal user debt");
        assertEq(totalDebtMid, totalDebtBefore, "spot manipulation should not change total nominal debt");

        _updateTwapAfterPeriod();

        uint256 cashAfter = lending.cash();
        uint256 debtAfter = lending.debtOf(alice);
        uint256 totalDebtAfter = lending.totalDebt();

        assertEq(cashAfter, cashBefore, "twap update should not directly change lending cash");
        assertEq(debtAfter, debtBefore, "twap update should not directly change nominal user debt");
        assertEq(totalDebtAfter, totalDebtBefore, "twap update should not directly change nominal total debt");
    }
}
