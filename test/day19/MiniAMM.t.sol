// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day19/MiniAMM.sol";
import "./MockERC20.sol";

contract MiniAMMTest is Test {
    MockERC20 token0;
    MockERC20 token1;
    MiniAMM amm;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address carol = address(0x11);

    uint256 constant E = 1e18;

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        amm = new MiniAMM(address(token0), address(token1));

        token0.mint(alice, 1_000_000e18);
        token1.mint(alice, 1_000_000e18);
        token0.mint(bob, 1_000_000e18);
        token1.mint(bob, 1_000_000e18);
        token0.mint(carol, 1_000_000e18);
        token1.mint(carol, 1_000_000e18);

        vm.prank(alice);
        token0.approve(address(amm), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(amm), type(uint256).max);

        vm.prank(bob);
        token0.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(amm), type(uint256).max);

        vm.prank(carol);
        token0.approve(address(amm), type(uint256).max);
        vm.prank(carol);
        token1.approve(address(amm), type(uint256).max);
    }

    function _seedPool() internal {
        vm.prank(alice);
        amm.addLiquidity(1000e18, 1000e18);
    }

    function test_AddLiquidity_InitialMint() public {
        uint256 amount0 = 1000e18;
        uint256 amount1 = 4000e18;

        vm.prank(alice);
        uint256 shares = amm.addLiquidity(amount0, amount1);

        uint256 expectedShares = sqrt(amount0 * amount1);

        assertEq(shares, expectedShares);
        assertEq(amm.totalShares(), expectedShares);
        assertEq(amm.balanceOf(alice), expectedShares);
        assertEq(amm.reserve0(), amount0);
        assertEq(amm.reserve1(), amount1);
    }

    function test_AddLiquidity_ProportionalMint() public {
        _seedPool();
        uint256 oldTotalShares = amm.totalShares();

        vm.prank(bob);
        uint256 shares = amm.addLiquidity(100e18, 100e18);

        uint256 expectedShares = (100e18 * oldTotalShares) / 1000e18;

        assertEq(shares, expectedShares);
        assertEq(amm.balanceOf(bob), expectedShares);
        assertEq(amm.totalShares(), oldTotalShares + expectedShares);
        assertEq(amm.reserve0(), 1100 * E);
        assertEq(amm.reserve1(), 1100 * E);
    }

    function test_AddLiquidity_RevertIfWrongRatio() public {
        _seedPool();

        vm.prank(bob);
        vm.expectRevert(MiniAMM.InvalidRatio.selector);
        amm.addLiquidity(100 * E, 120 * E);
    }

    function test_RemoveLiquidity_ReturnsUnderlying() public {
        _seedPool();

        uint256 aliceShares = amm.balanceOf(alice);
        uint256 removeShares = aliceShares / 2;

        uint256 aliceT0Before = token0.balanceOf(alice);
        uint256 aliceT1Before = token1.balanceOf(alice);

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = amm.removeLiquidity(removeShares);

        assertEq(amount0, 500 * E);
        assertEq(amount1, 500 * E);

        assertEq(token0.balanceOf(alice), aliceT0Before + amount0);
        assertEq(token1.balanceOf(alice), aliceT1Before + amount1);

        assertEq(amm.reserve0(), 500 * E);
        assertEq(amm.reserve1(), 500 * E);
        assertEq(amm.balanceOf(alice), aliceShares - removeShares);
    }

    function test_RemoveLiquidity_RevertIfInsufficientShares() public {
        _seedPool();

        vm.prank(bob);
        vm.expectRevert(MiniAMM.InsufficientShares.selector);
        amm.removeLiquidity(1);
    }

    function test_GetAmountOut_Token0ToToken1() public {
        _seedPool();

        uint256 amountIn = 100 * E;
        uint256 expectedOut = getAmountOutFormula(amountIn, 1000 * E, 1000 * E);

        uint256 quoted = amm.getAmountOut(amountIn, address(token0));
        assertEq(quoted, expectedOut);
    }

    function test_GetAmountOut_Token1ToToken0() public {
        _seedPool();

        uint256 amountIn = 100 * E;
        uint256 expectedOut = getAmountOutFormula(amountIn, 1000 * E, 1000 * E);

        uint256 quoted = amm.getAmountOut(amountIn, address(token1));
        assertEq(quoted, expectedOut);
    }

    function test_Swap0For1_Works() public {
        _seedPool();

        uint256 amount0In = 100 * E;
        uint256 expectedOut = getAmountOutFormula(
            amount0In,
            1000 * E,
            1000 * E
        );

        uint256 bobT1Before = token1.balanceOf(bob);

        vm.prank(bob);
        uint256 amount1Out = amm.swap0For1(amount0In, 0);

        assertEq(amount1Out, expectedOut);
        assertEq(token1.balanceOf(bob), bobT1Before + expectedOut);
        assertEq(amm.reserve0(), 1100 * E);
        assertEq(amm.reserve1(), 1000 * E - expectedOut);
    }

    function test_Swap1For0_Works() public {
        _seedPool();

        uint256 amount1 = 100e18;
        uint256 expectedOut = getAmountOutFormula(amount1, 1000 * E, 1000 * E);
        uint256 bobT0Before = token0.balanceOf(bob);
        vm.prank(bob);
        uint256 amount0 = amm.swap1For0(amount1, 0);

        assertEq(amount0, expectedOut);
        assertEq(token0.balanceOf(bob), bobT0Before + expectedOut);
        assertEq(amm.reserve1(), 1100 * E);
        assertEq(amm.reserve0(), 1000 * E - expectedOut);
    }

    function test_Swap_RevertIfSlippageExceeded() public {
        _seedPool();

        uint256 amount0In = 100 * E;
        uint256 quoted = getAmountOutFormula(amount0In, 1000 * E, 1000 * E);

        vm.prank(bob);
        vm.expectRevert(MiniAMM.InsufficientOutput.selector);
        amm.swap0For1(amount0In, quoted + 1);
    }

    function test_K_DoesNotDecrease_AfterSwap() public {
        _seedPool();

        uint256 oldK = amm.reserve0() * amm.reserve1();

        vm.prank(bob);
        amm.swap0For1(100 * E, 0);

        uint256 newK = amm.reserve0() * amm.reserve1();

        assertGe(newK, oldK);
    }

    function test_LPShareOwnershipMatchesPoolFraction() public {
        _seedPool();

        vm.prank(bob);
        amm.addLiquidity(1000 * E, 1000 * E);

        uint256 aliceShares = amm.balanceOf(alice);
        uint256 totalShares = amm.totalShares();

        assertEq(aliceShares, totalShares / 2);
        assertEq(amm.reserve0(), 2000 * E);
        assertEq(amm.reserve1(), 2000 * E);
    }

    function test_RoundTripSwap_UserCannotProfitForFree() public {
        _seedPool();

        uint256 bobT0Before = token0.balanceOf(bob);

        vm.startPrank(bob);
        uint256 out1 = amm.swap0For1(100 * E, 0);
        amm.swap1For0(out1, 0);
        vm.stopPrank();

        uint256 bobT0After = token0.balanceOf(bob);

        assertLt(bobT0After, bobT0Before);
    }

    function testFuzz_Swap0For1_KNonDecreasing(uint96 rawAmountIn) public {
        _seedPool();

        uint256 amountIn = bound(uint256(rawAmountIn), 1e12, 200 * E);

        uint256 oldK = amm.reserve0() * amm.reserve1();

        vm.prank(bob);
        amm.swap0For1(amountIn, 0);

        uint256 newK = amm.reserve0() * amm.reserve1();
        assertGe(newK, oldK);
    }

    function testFuzz_AddThenRemove_SharesAccounting(
        uint96 raw0,
        uint96 raw1
    ) public {
        uint256 amount0 = bound(uint256(raw0), 1e12, 10_000 * E);
        uint256 amount1 = bound(uint256(raw1), 1e12, 10_000 * E);

        vm.prank(alice);
        uint256 shares = amm.addLiquidity(amount0, amount1);

        vm.prank(alice);
        (uint256 out0, uint256 out1) = amm.removeLiquidity(shares);

        assertEq(out0, amount0);
        assertEq(out1, amount1);
        assertEq(amm.reserve0(), 0);
        assertEq(amm.reserve1(), 0);
        assertEq(amm.totalShares(), 0);
    }

    function sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y == 0) return 0;
        if (y <= 3) return 1;

        z = y;
        uint256 x = y / 2 + 1;
        while (x < z) {
            z = x;
            x = (y / x + x) / 2;
        }
    }

    function getAmountOutFormula(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256) {
        uint256 amountInWithFee = amountIn * 997;
        return
            (reserveOut * amountInWithFee) /
            (reserveIn * 1000 + amountInWithFee);
    }
}
