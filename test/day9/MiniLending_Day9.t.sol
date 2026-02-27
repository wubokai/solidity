// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {MiniLending, IERC20Like, IOracle} from "../../src/day9/MiniLendingV1.3.sol";

contract MockERC20 is IERC20Like {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) { name = n; symbol = s; }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract MockOracle is IOracle {
    uint256 public p; // priceCollateralInAsset (1e18)
    function set(uint256 _p) external { p = _p; }
    function priceCollateralInAsset() external view returns (uint256) { return p; }
}


contract MiniLendingDay9Test is Test {

    MockERC20 asset;
    MockERC20 collat;
    MockOracle oracle;
    MiniLending lending;

    address alice = address(0xA11CE);
    address liq   = address(0xB0B);

    function setUp() public {
        asset = new MockERC20("ASSET","A");
        collat = new MockERC20("COLL","C");
        oracle = new MockOracle();

        oracle.set(1e18);

        lending = new MiniLending(
            IERC20Like(address(asset)),
            IERC20Like(address(collat)),
            IOracle(address(oracle)),
            0,        // ratePerSecond
            8_000,    // ltv 80%
            8_500,    // liqThreshold 85%
            1_000,    // liqBonus 10%
            5_000     // closeFactor 50%
        );

        asset.mint(address(this), 1_000_000e18);
        asset.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);

        collat.mint(alice, 1_000e18);
        asset.mint(liq, 1_000_000e18);

        vm.prank(alice);
        MockERC20(address(collat)).approve(address(lending), type(uint256).max);

        vm.prank(liq);
        MockERC20(address(asset)).approve(address(lending), type(uint256).max);


    }


    function _aliceDepositCollatAndBorrow(uint256 collatAmt, uint256 borrowAmt) internal {
        vm.startPrank(alice);
        lending.depositCollateral(collatAmt);
        lending.borrow(borrowAmt);
        vm.stopPrank();
    }

    function test_liquidate_only_when_HF_below_1() public { 
        _aliceDepositCollatAndBorrow(100e18, 50e18);
        vm.startPrank(liq);
        vm.expectRevert(MiniLending.NotLiquidatable.selector);
        lending.liquidate(alice, 50e18);
        vm.stopPrank();
    }

    function test_closeFactor_caps_repayUsed() public {

        _aliceDepositCollatAndBorrow(100e18, 50e18);
        oracle.set(5e17);
        uint256 debtBefore = lending.debtOf(alice);
        assertGt(debtBefore, 0);
        uint256 maxClose = debtBefore * 5_000 / 10_000; // closeFactor 50%
        vm.startPrank(liq);
        (uint256 repayUsed,,) = lending.liquidate(alice, type(uint256).max);
        vm.stopPrank();

        assertLe(repayUsed, maxClose);
        assertLe(repayUsed, debtBefore);

    }

    function test_seize_math_basic() public {

        _aliceDepositCollatAndBorrow(100e18,80e18);
        oracle.set(7e17); // HF = 0.875 < liqThreshold 0.85% => liquidatable
        vm.startPrank(liq);
        (uint256 repayUsed,, uint256 seized) = lending.liquidate(alice, 10e18);
        vm.stopPrank();    
        assertGt(seized, 15e18);
        assertLt(seized, 16e18);
        assertEq(repayUsed, 10e18);

    }


    function test_backsolve_when_collateral_insufficient() public {
        _aliceDepositCollatAndBorrow(1e18, 50e18);
        oracle.set(5e17);

        uint256 colBefore = lending.collateralOf(alice);
        assertEq(colBefore, 1e18);

        vm.startPrank(liq);
        (uint256 repayUsed,, uint256 seized) = lending.liquidate(alice, 100e18);
        vm.stopPrank();

        assertEq(seized, 1e18);

        assertLt(repayUsed, 100e18);
        assertGt(repayUsed, 0);

    }

    function test_withdrawCollateral_reverts_if_not_solvent() public {

        _aliceDepositCollatAndBorrow(100e18, 80e18);

        vm.startPrank(alice);
        vm.expectRevert(MiniLending.NotSolvent.selector);
        lending.withdrawCollateral(10e18);
        vm.stopPrank();
        
    }



}
