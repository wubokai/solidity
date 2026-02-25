// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "../../lib/forge-std/src/StdInvariant.sol";
import {Handler as HD} from "./Handler.sol";
import "../../lib/forge-std/src/Test.sol";
import "../../src/day8/MiniLendingV1.2.sol";
import {MockERC20 as Day8MockERC20} from "../../src/day8/MockERC20.sol";

contract InvariantTest is StdInvariant, Test {
    Day8MockERC20 token;
    MiniLending pool;
    HD handler;

    uint256 public lastSeenIndex;

    function setUp() external {
        token = new Day8MockERC20("Mock", "MOCK", 18);
        pool = new MiniLending(IERC20Like(address(token)), 1e12);

        handler = new HD(pool, token);

        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.actWarp.selector;
        selectors[1] = handler.actAccrue.selector;
        selectors[2] = handler.actDeposit.selector;
        selectors[3] = handler.actWithdraw.selector;
        selectors[4] = handler.actBorrow.selector;
        selectors[5] = handler.actRepay.selector;
        selectors[6] = handler.actDonate.selector;

        targetSelector(
            FuzzSelector({addr: address(handler), selectors: selectors})
        );

        lastSeenIndex = pool.borrowIndex();
    }

    function invariant_borrowIndex_monotonic_nonDecreasing() external {
        uint256 idx = pool.borrowIndex();
        assertGe(idx, lastSeenIndex);
        lastSeenIndex = idx;
    }

    function invariant_totalDebt_formula_consistency() external view {
        uint256 td = pool.totalDebt();
        uint256 derived = (pool.totalBorrowShares() * pool.borrowIndex()) /
            1e18;
        assertEq(td, derived);
    }

    function invariant_basic_accounting_sanity() external view {
        uint256 _cash = token.balanceOf(address(pool));
        uint256 _debt = pool.totalDebt();
        assertGe(_cash + _debt, _cash);
    }
}
