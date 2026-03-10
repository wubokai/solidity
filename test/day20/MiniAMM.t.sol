// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day20/MiniAMM.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "bal");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(balanceOf[from] >= amount, "bal");
        require(allowed >= amount, "allow");

        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}


contract MiniAMMTest is Test {

    MockERC20 token0;
    MockERC20 token1;
    MiniAMM amm;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);

    function setUp() external{

        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        amm = new MiniAMM(IERC20Like(address(token0)), IERC20Like(address(token1)));

        token0.mint(alice, 1_000_000e18);
        token1.mint(alice, 1_000_000e18);
        token0.mint(bob, 1_000_000e18);
        token1.mint(bob, 1_000_000e18);

        vm.prank(alice);
        token0.approve(address(amm), type(uint256).max);
        vm.prank(alice);
        token1.approve(address(amm), type(uint256).max);

        vm.prank(bob);
        token0.approve(address(amm), type(uint256).max);
        vm.prank(bob);
        token1.approve(address(amm), type(uint256).max);
    }

    function _seedPool() internal {
        vm.prank(alice);
        amm.addLiquidity(alice, 1000e18, 1000e18, 1000e18, 1000e18, block.timestamp + 1 days);
    }

    function test_InitialAddLiquidity() external {
        vm.prank(alice);
        (uint256 amount0, uint256 amount1, uint256 shares) = amm.addLiquidity(alice, 1000e18, 1000e18, 1000e18, 1000e18, block.timestamp + 1 days);

        assertEq(amount0, 1000e18);
        assertEq(amount1, 1000e18);
        assertGt(shares, 0);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0, 1000e18);
        assertEq(r1, 1000e18);

        assertEq(token0.balanceOf(address(amm)), r0);
        assertEq(token1.balanceOf(address(amm)), r1);
    
    }
    
    function test_AddLiquidity_UsesOptimalAmounts() external {
        _seedPool();

        vm.prank(bob);
        (uint256 amount0, uint256 amount1, uint256 shares) = amm.addLiquidity(
            bob,
            100e18,
            150e18,
            100e18,
            100e18,
            block.timestamp + 1 days
        );

        assertEq(amount0, 100e18);
        assertEq(amount1, 100e18);
        assertGt(shares, 0);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(r0, 1100e18);
        assertEq(r1, 1100e18);
    }

    function test_AddLiquidity_RevertWhenExpired() external {
        vm.warp(100);

        vm.prank(alice);
        vm.expectRevert(MiniAMM.Expired.selector);
        amm.addLiquidity(
            alice,
            100e18,
            100e18,
            100e18,
            100e18,
            99
        );
    }

    function test_AddLiquidity_RevertOnSlippage() external {
        _seedPool();

        vm.prank(bob);
        vm.expectRevert(MiniAMM.SlippageExceeded.selector);
        amm.addLiquidity(bob, 100e18, 150e18, 100e18, 120e18, block.timestamp + 1 days);
    }

    function test_RemoveLiquidity() external {
        _seedPool();

        uint256 share = amm.balanceOf(alice);
        uint256 shares = share/2;

        vm.prank(alice);
        (uint256 amount0, uint256 amount1) = amm.removeLiquidity(shares, 0, 0, alice, block.timestamp + 1 days);

        assertGt(amount0,0);
        assertGt(amount1,0);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(token0.balanceOf(address(amm)), r0);
        assertEq(token1.balanceOf(address(amm)), r1);
    
    
    }

    function test_RemoveLiquidity_RevertWhenExpired() external {
        _seedPool();

        uint256 aliceShares = amm.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(MiniAMM.Expired.selector);
        amm.removeLiquidity(aliceShares / 2, 0, 0, alice, block.timestamp - 1);
    }

    function test_RemoveLiquidity_RevertOnMinAmounts() external {
        _seedPool();

        uint256 shares = amm.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(MiniAMM.SlippageExceeded.selector);
        // MINIMUM_LIQUIDITY is permanently locked, so removing all user shares
        // returns slightly less than 1000e18 for each token.
        amm.removeLiquidity(shares, 1000e18, 1000e18, alice, block.timestamp + 1 days);
    
    }

    function test_Swap0For1() external {
        _seedPool();

        uint256 before = token1.balanceOf(bob);
        uint256 expectedOut = amm.getAmountOut(100e18, 1000e18, 1000e18);

        vm.prank(bob);
        uint256 out = amm.swap0For1(100e18, expectedOut, bob, block.timestamp + 1 days);

        assertEq(out, expectedOut);
        assertEq(token1.balanceOf(bob), before + out);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(token0.balanceOf(address(amm)), r0);
        assertEq(token1.balanceOf(address(amm)), r1);   
    }

    function test_Swap1For0() external {
        _seedPool();

        uint256 before = token0.balanceOf(bob);
        uint256 expectedOut = amm.getAmountOut(100e18, 1000e18, 1000e18);

        vm.prank(bob);
        uint256 out = amm.swap1For0(100e18, expectedOut, bob, block.timestamp + 1 days);

        assertEq(out, expectedOut);
        assertEq(token0.balanceOf(bob), before + out);

        (uint256 r0, uint256 r1) = amm.getReserves();
        assertEq(token0.balanceOf(address(amm)), r0);
        assertEq(token1.balanceOf(address(amm)), r1);   
    }


    function test_Swap_RevertWhenExpired() external {
        _seedPool();

        vm.prank(bob);
        vm.expectRevert(MiniAMM.Expired.selector);
        amm.swap0For1(100e18, 0, bob, block.timestamp - 1);
    }

    function test_Swap_RevertOnMinOut() external {
        _seedPool();

        uint256 expectedOut = amm.getAmountOut(100e18, 1000e18, 1000e18);

        vm.prank(bob);
        vm.expectRevert(MiniAMM.SlippageExceeded.selector);
        amm.swap0For1(
            100e18,
            expectedOut + 1,
            bob,
            block.timestamp + 1 days
        );
    }

    function test_Quote() external view {
        uint256 out = amm.quote(100e18, 1000e18, 2000e18);
        assertEq(out, 200e18);
    }

    function test_GetAmountOut_IsLessThanQuoteBecauseFeeAndPriceImpact() external view {
        uint256 quoted = amm.quote(100e18, 1000e18, 1000e18);
        uint256 amountOut = amm.getAmountOut(100e18, 1000e18, 1000e18);

        assertLt(amountOut, quoted);
    }

    function test_GetAmountIn() external view {
        uint256 amountIn = amm.getAmountIn(50e18, 1000e18, 1000e18);
        uint256 amountOut = amm.getAmountOut(amountIn, 1000e18, 1000e18);

        assertGe(amountOut, 50e18);
    }

    function testFuzz_GetAmountOut_LessThanReserveOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) external view {
        vm.assume(amountIn > 0 && amountIn < 1e30);
        vm.assume(reserveIn > 1e6 && reserveIn < 1e30);
        vm.assume(reserveOut > 1e6 && reserveOut < 1e30);

        uint256 out = amm.getAmountOut(amountIn, reserveIn, reserveOut);
        assertLt(out, reserveOut);
    }

    function testFuzz_Quote_LinearProportion(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external view {
        vm.assume(amountA > 0 && amountA < 1e30);
        vm.assume(reserveA > 0 && reserveA < 1e30);
        vm.assume(reserveB > 0 && reserveB < 1e30);

        uint256 amountB = amm.quote(amountA, reserveA, reserveB);

        assertEq(amountB, (amountA * reserveB) / reserveA);
    }

    function test_K_DoesNotDecreaseOnSwap() external {
        _seedPool();

        (uint256 r0Before, uint256 r1Before) = amm.getReserves();
        uint256 kBefore = r0Before * r1Before;

        vm.prank(bob);
        amm.swap0For1(100e18, 0, bob, block.timestamp + 1 days);

        (uint256 r0After, uint256 r1After) = amm.getReserves();
        uint256 kAfter = r0After * r1After;

        assertGe(kAfter, kBefore);
    }


}
