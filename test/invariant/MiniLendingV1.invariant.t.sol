// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";
import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {MiniLendingV1} from "../../src/day6/MiniLendingV1.sol";
import {MockOracle} from "../../src/day6/MockOracle.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}
    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract Handler is Test {
    MiniLendingV1 public pool;
    MockERC20 public asset;
    MockERC20 public col;
    MockOracle public oracle;
    // ===== add state for "pure accrue" monotonic check =====
    uint256 public lastDebtAfterPureAccrue;
    bool public lastActionWasPureAccrue;

    uint256 public ghostTotalDeposits;
    address[] public users;

    constructor(
        MiniLendingV1 _pool,
        MockERC20 _asset,
        MockERC20 _col,
        MockOracle _oracle
    ) {
        pool = _pool;
        asset = _asset;
        col = _col;
        oracle = _oracle;
        lastDebtAfterPureAccrue = pool.totalDebt();
        lastActionWasPureAccrue = false;
        // seed users
        for (uint256 i = 0; i < 6; i++) {
            address u = address(
                uint160(uint256(keccak256(abi.encode("USER", i))))
            );
            users.push(u);

            asset.mint(u, 1_000_000e18);
            col.mint(u, 1_000_000e18);

            vm.startPrank(u);
            asset.approve(address(pool), type(uint256).max);
            col.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _markNotPureAccrue() internal {
        lastActionWasPureAccrue = false;
    }

    function _u(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    //actions
    function act_deposit(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 50_000e18);

        uint256 td0 = pool.totalDeposits();

        vm.prank(u);
        pool.deposit(amt);

        uint256 td1 = pool.totalDeposits();
        // deposit 应该只让 totalDeposits 增加
        assertGe(td1, td0);
        ghostTotalDeposits += (td1 - td0);
    }

    function act_withdraw(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 20_000e18);

        uint256 td0 = pool.totalDeposits();

        vm.startPrank(u);
        try pool.withdraw(amt) {
            uint256 td1 = pool.totalDeposits();
            assertLe(td1, td0);
            ghostTotalDeposits -= (td0 - td1);
        } catch {}
        vm.stopPrank();
    }

    function act_depositCollateral(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 10_000e18);

        vm.prank(u);
        pool.depositCollateral(amt);
        _markNotPureAccrue();
    }

    function act_withdrawCollateral(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 5_000e18);
        vm.startPrank(u);
        try pool.withdrawCollateral(amt) {} catch {}
        vm.stopPrank();
        _markNotPureAccrue();
    }

    function act_borrow(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 20_000e18);

        vm.startPrank(u);
        try pool.borrow(amt) {} catch {}
        vm.stopPrank();
        _markNotPureAccrue();
    }

    function act_repay(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 20_000e18);

        vm.startPrank(u);
        try pool.repay(amt) {} catch {}
        vm.stopPrank();
        _markNotPureAccrue();
    }

    function act_warp(uint256 dt) external {
        dt = bound(dt, 1, 14 days);
        vm.warp(block.timestamp + dt);
        pool.accrueInterest();

        lastActionWasPureAccrue = true;
        lastDebtAfterPureAccrue = pool.totalDebt();
    }

    function act_setPrice(uint256 p) external {
        p = bound(p, 2e17, 5e18);
        oracle.setPrice(p);
    }

    function sumDebtShares() external view returns (uint256 s) {
        for (uint256 i = 0; i < users.length; i++) {
            s += pool.debtSharesOf(users[i]);
        }
    }

    function act_donate(uint256 seed, uint256 amt) external {
        address u = _u(seed);
        amt = bound(amt, 1e18, 50_000e18);

        vm.prank(u);
        asset.transfer(address(pool), amt);

        _markNotPureAccrue();
    }
}

contract MiniLendingV1Invariant is StdInvariant, Test {
    MockERC20 asset;
    MockERC20 col;
    MockOracle oracle;
    MiniLendingV1 pool;
    Handler handler;

    function setUp() public {
        asset = new MockERC20("Asset", "AST", 18);
        col = new MockERC20("Collateral", "COL", 18);
        oracle = new MockOracle(2e18);

        uint256 ltvBps = 7500;
        uint256 liqThBps = 8000;
        uint256 liqBonusBps = 500;

        uint256 secondsPerYear = 365 days;
        uint256 slopeRay = (5e16 * 1e27) / secondsPerYear; // 5% APR
        uint256 baseRay = 0;

        pool = new MiniLendingV1(
            asset,
            col,
            oracle,
            ltvBps,
            liqThBps,
            liqBonusBps,
            baseRay,
            slopeRay
        );
        handler = new Handler(pool, asset, col, oracle);
        targetContract(address(handler));

        // seed pool liquidity (LP)
        address lp = address(0xBEEF);
        asset.mint(lp, 5_000_000e18);
        vm.startPrank(lp);
        asset.approve(address(pool), type(uint256).max);
        pool.deposit(5_000_000e18);
        vm.stopPrank();
    }

    function invariant_debtShares_conservation() public view {
        uint256 sum = handler.sumDebtShares();
        assertEq(pool.totalDebtShares(), sum);
    }

    function invariant_accounting_sanity() public view {
        uint256 bal = asset.balanceOf(address(pool));
        assertGe(bal + pool.totalDebt(), pool.totalDeposits());
    }

    function invariant_debtMonotonicOnPureAccrue() public view {
        if (handler.lastActionWasPureAccrue() && pool.totalDebt() > 0) {
            assertGe(pool.totalDebt(), handler.lastDebtAfterPureAccrue());
        }
    }

    function invariant_sumUserDebtSharesLeTotal() public view {
        uint256 sum = handler.sumDebtShares();
        assertLe(sum, pool.totalDebtShares());
    }

    
}
