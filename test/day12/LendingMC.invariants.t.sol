// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {MiniLendingMC_BadDebt} from "../../src/day12/MiniLendingMC_BadDebt.sol";
import {LendingMCHandler} from "./LendingMCHandler.t.sol";

import {MockERC20} from "./MockERC20.sol";
import {MockOracle} from "./MockOracle.sol";

contract LendingMCInvariants is StdInvariant, Test {
    MiniLendingMC_BadDebt pool;
    MockERC20 asset;
    MockERC20 col1;
    MockERC20 col2;
    MockOracle oracle;

    LendingMCHandler handler;

    address[] users;
    address[] cols;

    function setUp() external {
        // ---- deploy mocks ----
        asset = new MockERC20("Asset", "AST", 18);
        col1  = new MockERC20("Col1", "C1", 18);
        col2  = new MockERC20("Col2", "C2", 18);
        oracle = new MockOracle();

        // 初始价格：$1
        oracle.setPrice(address(asset), 1e18);
        oracle.setPrice(address(col1),  1e18);
        oracle.setPrice(address(col2),  1e18);

        // ---- deploy pool ----
        // ratePerSecond / reserveFactor 你可以按你 Day11/Day12 的配置改
        pool = new MiniLendingMC_BadDebt(address(asset), address(oracle), 1e10, 0.1e18);

        // list collaterals
        pool.listCollateral(address(col1), true);
        pool.listCollateral(address(col2), true);

        // ---- users ----
        for (uint256 i = 0; i < 8; i++) {
            users.push(makeAddr(string.concat("user", vm.toString(i))));
        }
        cols.push(address(col1));
        cols.push(address(col2));

        // ---- seed pool cash (so borrow has liquidity) ----
        // 让某个“LP”先给池子提供流动性：直接 mint+deposit
        address lp = makeAddr("lp");
        asset.mint(lp, 1e24);
        vm.startPrank(lp);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(1e24);
        vm.stopPrank();

        // ---- handler ----
        handler = new LendingMCHandler(pool, address(oracle), users, cols);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](12);
        selectors[0]  = handler.act_deposit.selector;
        selectors[1]  = handler.act_withdraw.selector;
        selectors[2]  = handler.act_depositCollateral.selector;
        selectors[3]  = handler.act_withdrawCollateral.selector;
        selectors[4]  = handler.act_borrow.selector;
        selectors[5]  = handler.act_repay.selector;
        selectors[6]  = handler.act_liquidate.selector;
        selectors[7]  = handler.act_donate.selector;
        selectors[8]  = handler.act_setPrice.selector;
        selectors[9]  = handler.act_warp.selector;
        selectors[10] = handler.act_accrue.selector;
        selectors[11] = handler.act_deposit.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_borrowIndex_positive() external view {
        assertGt(pool.borrowIndex(), 0);
    }

    function invariant_totalDebt_matches_shares_index() external view {
        uint256 expected = (pool.totalDebtShares() * pool.borrowIndex()) / 1e18;
        uint256 got = pool.totalDebt();

        if(got > expected) assertLe(got - expected,5);
        else assertLe(expected - got,5); 
    }

    function invariant_ghost_deposits_sum() external view {
        uint256 sum;
        for(uint256 i =0; i<users.length;i++){
            sum += handler.ghostDebtShares(users[i]);
        }

        assertEq(sum,handler.ghostTotalDebtShares());
    }

    /// 这个模型里，`equity = cash + debt + badDebt - totalDeposits - reserves`：
    /// - deposit/withdraw 只是现金与存款负债同增同减，equity 不变
    /// - borrow/repay/liquidate 主要在 cash<->debt 间迁移，equity 只会因 rounding 增加
    /// - accrueInterest 会把净利差 (interest - reservesAdded) 累到 equity
    /// - badDebt absorb 把 debt 迁移到 badDebt，equity 不变
    /// - donate 直接增加 equity
    /// 因此 equity 至少应覆盖 ghostDonated（允许极小 rounding 误差）。
    function invariant_accounting_identity_with_donation() external view {

        uint256 cash = asset.balanceOf(address(pool));
        uint256 debt = pool.totalDebt();
        uint256 res = pool.reserves();
        uint256 bd = pool.badDebt();
        uint256 dep = pool.totalDeposits();

        uint256 assetsTotal = cash + debt + bd;
        uint256 liabilitiesTotal = dep + res;
        assertGe(assetsTotal, liabilitiesTotal);

        uint256 equity = assetsTotal - liabilitiesTotal;

        uint256 donated = handler.ghostDonated();
        if (equity >= donated) return;
        assertLe(donated - equity, 10);
    }


}
