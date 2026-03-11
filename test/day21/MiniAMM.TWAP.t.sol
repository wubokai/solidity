// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";
import "../../src/day21/MiniAMM.sol";
import "../../src/day21/SimpleTWAPOracle.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }

        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MiniAMMTWAPTest is Test {

    MockERC20 token0;
    MockERC20 token1;
    MiniAMM amm;
    SimpleTWAPOracle oracle;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    uint256 constant ONE = 1e18;

    function setUp() external {

        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");
        amm = new MiniAMM(IERC20Like(address(token0)), IERC20Like(address(token1)));

        token0.mint(alice, 10_000 * ONE);
        token1.mint(alice, 10_000 * ONE);

        token0.mint(bob, 10_000 * ONE);
        token1.mint(bob, 10_000 * ONE);

        vm.startPrank(alice);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);

        amm.addLiquidity(
            alice,
            1_000 * ONE,
            1_000 * ONE,
            1_000 * ONE,
            1_000 * ONE,
            block.timestamp + 1 days
        );
        vm.stopPrank();

        oracle = new SimpleTWAPOracle(address(amm));
    

    }


    function test_InitialReserves() external view {
        (uint112 r0, uint112 r1, ) = amm.getReserves();
        assertEq(r0, 1_000 * ONE);
        assertEq(r1, 1_000 * ONE);
    }

    function test_TWAP_StableWithoutTrades() external {
        vm.warp(block.timestamp + 1 hours);

        oracle.update();

        uint256 out = oracle.consult(address(token0), ONE);
        assertEq(out, ONE);
    }

    function test_TWAP_ShortManipulationDoesNotFullyFollowSpot() external {
        vm.startPrank(bob);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        vm.stopPrank();

        // first, let normal price 1:1 live for 1 hour
        vm.warp(block.timestamp + 1 hours);
        oracle.update();

        // manipulate spot with a large swap
        vm.prank(bob);
        amm.swap0For1(500 * ONE, 0, bob, block.timestamp + 1 days);

        // immediately after manipulation, consult old TWAP still ~1
        uint256 twapBeforeSecondUpdate = oracle.consult(address(token0), ONE);
        assertEq(twapBeforeSecondUpdate, ONE);

        // move only a short time under manipulated spot
        vm.warp(block.timestamp + 10 minutes);
        oracle.update();

        uint256 twapAfter = oracle.consult(address(token0), ONE);
        uint256 spotAfter = _spotPrice0();

        // twap should have moved, but not fully to spot
        assertTrue(twapAfter < ONE);
        assertTrue(twapAfter > spotAfter);
    }

    function test_TWAP_ApproachesNewPriceIfManipulationPersists() external {
        vm.startPrank(bob);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours);
        oracle.update();

        vm.prank(bob);
        amm.swap0For1(500 * ONE, 0, bob, block.timestamp + 1 days);

        vm.warp(block.timestamp + 10 minutes);
        oracle.update();
        uint256 twapShort = oracle.consult(address(token0), ONE);

        vm.warp(block.timestamp + 2 hours);
        oracle.update();
        uint256 twapLong = oracle.consult(address(token0), ONE);

        uint256 spotAfter = _spotPrice0();

        // longer persistence -> TWAP closer to new spot
        assertTrue(twapLong < twapShort);
        assertTrue(twapLong >= spotAfter);
    }

    function test_Consult_Token1ToToken0() external {
        vm.warp(block.timestamp + 1 hours);
        oracle.update();

        uint256 out = oracle.consult(address(token1), ONE);
        assertEq(out, ONE);
    }

    function test_Sync_Works() external {
        vm.warp(block.timestamp + 1 hours);
        amm.sync();

        (
            uint256 p0c,
            uint256 p1c,

        ) = amm.currentCumulativePrices();

        assertGt(p0c, 0);
        assertGt(p1c, 0);
    }


    function _spotPrice0() internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = amm.getReserves();
        return (uint256(r1) * 1e18) / uint256(r0);
    }

}
