// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdUtils.sol";
import {MiniLendingMC_BadDebt} from "../../src/day12/MiniLendingMC_BadDebt.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

interface IOracleLike {
    function setPrice(address token, uint256 pE18) external;
    function price(address token) external view returns (uint256);
}

contract LendingMCHandler is Test {

    MiniLendingMC_BadDebt pool;
    IERC20Like public asset;
    IOracleLike public oracle;

    address[] public users;
    address[] public cols;

    mapping(address => uint256) public ghostDeposit;
    uint256 public ghostTotalDeposits;

    mapping (address => uint256) public ghostDebtShares;
    uint256 public ghostTotalDebtShares;

    mapping(address => mapping(address => uint256)) public ghostCollateral;
    uint256 public ghostDonated;

    constructor(
        MiniLendingMC_BadDebt _pool,
        address _oracle,
        address[] memory _users,
        address[] memory _cols
    ){
        pool = _pool;
        asset = IERC20Like(_pool.asset());
        oracle = IOracleLike(_oracle);
        users = _users;
        cols = _cols;
    }

    function _pickUser(uint256 s) internal view returns (address) {
        return users[s % users.length];
    }

    function _pickCol(uint256 s) internal view returns (address) {
        return cols[s % cols.length];
    }

    function _nz(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        x = bound(x, min, max);
        if (x == 0) x = min;
        return x;
    }

    function act_deposit(uint256 userSeed, uint256 amtSeed) external {
        address u = _pickUser(userSeed);
        uint256 amt = _nz(amtSeed, 1, 1e24);

        deal(address(asset),u,asset.balanceOf(u) + amt);
        vm.startPrank(u);
        asset.approve(address(pool), amt);
        pool.deposit(amt);
        vm.stopPrank();

        ghostDeposit[u] += amt;
        ghostTotalDeposits += amt;

    }

    function act_withdraw(uint256 userSeed, uint256 amtSeed) external {
        address u = _pickUser(userSeed);
        uint256 maxW = ghostDeposit[u];
        if(maxW == 0) return;

        uint256 amt = bound(amtSeed,1, maxW);

        vm.startPrank(u);
        try pool.withdraw(amt){
            ghostDeposit[u] -= amt;
            ghostTotalDeposits -= amt;
        } catch {}
        vm.stopPrank();

    }


    function act_depositCollateral(uint256 userSeed, uint256 colSeed, uint256 amtSeed) external {
        address u =_pickUser(userSeed);
        address c = _pickCol(colSeed);

        uint256 amt = _nz(amtSeed, 1, 1e24);
        deal(c,u,IERC20Like(c).balanceOf(u) + amt);
        vm.startPrank(u);
        IERC20Like(c).approve(address(pool), amt);
        try pool.depositCollateral(c,amt){
            ghostCollateral[u][c] += amt;
        } catch {}

        vm.stopPrank();

    }

    function act_withdrawCollateral(uint256 userSeed, uint256 colSeed, uint256 amtSeed) external {

        address u =_pickUser(userSeed);
        address c = _pickCol(colSeed);

        uint256 maxW = ghostCollateral[u][c];
        if(maxW == 0 ) return;

        uint256 amt = bound(amtSeed, 1, maxW);
        vm.startPrank(u);

        try pool.withdrawCollateral(c, amt){
            ghostCollateral[u][c] -= amt;
        } catch {}
        vm.stopPrank();
    }

    function act_borrow(uint256 userSeed, uint256 amtSeed) external {
        address u = _pickUser(userSeed);
        uint256 amt = _nz(amtSeed, 1, 1e24);

        vm.startPrank(u);

        uint256 sharesBefore = pool.debtSharesOf(u);
        uint256 totalSharesBefore = pool.totalDebtShares();

        try pool.borrow(amt){
            uint256 sharesAfter = pool.debtSharesOf(u);
            uint256 deltaShares = sharesAfter - sharesBefore;

            ghostDebtShares[u] += deltaShares;
            ghostTotalDebtShares += (pool.totalDebtShares() - totalSharesBefore);
        } catch {}

        vm.stopPrank();

    }

    function act_repay(uint256 userSeed, uint256 amtSeed) external {
        address u = _pickUser(userSeed);
        if (ghostDebtShares[u] == 0) return;

        uint256 amt = _nz(amtSeed, 1, 1e24);
        deal(address(asset),u,asset.balanceOf(u)+ amt);
        uint256 sharesBefore = pool.debtSharesOf(u);
        uint256 totalSharesBefore = pool.totalDebtShares();

        vm.startPrank(u);
        asset.approve(address(pool), amt);
        try pool.repay(amt){
            uint256 sharesAfter = pool.debtSharesOf(u);
            uint256 burned = sharesBefore - sharesAfter;

            if(burned > ghostDebtShares[u]) burned = ghostDebtShares[u];
            ghostDebtShares[u] -= burned;
            uint256 totalBurned = totalSharesBefore - pool.totalDebtShares();
            if (totalBurned > ghostTotalDebtShares) totalBurned = ghostTotalDebtShares;
            ghostTotalDebtShares -= totalBurned;

        } catch {}
        vm.stopPrank();
    }

    function act_liquidate(
        uint256 liqSeed,
        uint256 brwSeed,
        uint256 colSeed,
        uint256 repaySeed
    ) external {
        address liq = _pickUser(liqSeed);
        address brw = _pickUser(brwSeed);
        if (liq == brw) return;

        if (pool.healthFactor(brw) >= 1e18) return;
        address c = _pickCol(colSeed);
        uint256 repayAmt = _nz(repaySeed, 1, 1e24);
        deal(address(asset), liq, asset.balanceOf(liq) + repayAmt);

        uint256 brwSharesBefore = pool.debtSharesOf(brw);
        uint256 totalSharesBefore = pool.totalDebtShares();
        uint256 colBefore = pool.collateralOf(brw, c);

        vm.startPrank(liq);
        asset.approve(address(pool), repayAmt);
        try pool.liquidate(brw, c, repayAmt){
            uint256 colAfter = pool.collateralOf(brw,c);
            uint256 seized = colBefore - colAfter;
            uint256 had = ghostCollateral[brw][c];
            ghostCollateral[brw][c] -= seized;

            uint256 brwSharesAfter = pool.debtSharesOf(brw);
            uint256 burned = brwSharesBefore - brwSharesAfter;

            if (burned > ghostDebtShares[brw]) burned = ghostDebtShares[brw];
            ghostDebtShares[brw] -= burned;

            uint256 totalBurned = totalSharesBefore - pool.totalDebtShares();
            if (totalBurned > ghostTotalDebtShares) totalBurned = ghostTotalDebtShares;
            ghostTotalDebtShares -= totalBurned;

        } catch {}

        vm.stopPrank();

    }

    function act_donate(uint256 userSeed, uint256 amtSeed) external {
        address u = _pickUser(userSeed);
        uint256 amt = _nz(amtSeed, 1, 1e24);

        deal(address(asset), u, asset.balanceOf(u) + amt);

        vm.startPrank(u);
        asset.transfer(address(pool), amt);
        vm.stopPrank();

        ghostDonated += amt;
    }

    function act_setPrice(uint256 tokenSeed, uint256 priceSeed) external {

        address t = tokenSeed % 2 == 0 ? address(asset) : _pickCol(tokenSeed);
        uint256 p = bound(priceSeed, 1e6, 1e30); // 1e18 计价，范围别太极端
        oracle.setPrice(t, p);
    }

    function act_warp(uint256 dtSeed) external {
        uint256 dt = bound(dtSeed, 0, 14 days);
        vm.warp(block.timestamp + dt);
    }

    function act_accrue() external {
        pool.accrueInterest();
    }

}