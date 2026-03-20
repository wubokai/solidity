// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../../src/day26/MiniLendingMC_BadDebt_TWAP.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BAL");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ALLOW");
        require(balanceOf[from] >= amount, "BAL");

        allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockOracleRouter is IOracleRouterLike {
    mapping(address => uint256) public price;

    function setPrice(address asset, uint256 px) external {
        price[asset] = px;
    }

    function getPrice(address asset) external view returns (uint256) {
        return price[asset];
    }
}



contract Day26HardeningTest is Test {
    MockERC20 internal usdc;
    MockERC20 internal weth;
    MockERC20 internal wbtc;

    MockOracleRouter internal router1;
    MockOracleRouter internal router2;

    MiniLendingMC_BadDebt_TWAP internal lending;

    address internal alice = address(0xA11CE);
    address internal bob   = address(0xB0B);
    address internal lp    = address(0x1A1);
    address internal owner;
    address internal attacker = address(0xBAD);

    function setUp() public {
        owner = address(this);

        usdc = new MockERC20("Mock USD", "mUSD");
        weth = new MockERC20("Wrapped ETH", "WETH");
        wbtc = new MockERC20("Wrapped BTC", "WBTC");

        router1 = new MockOracleRouter();
        router2 = new MockOracleRouter();

        // 价格全部按 1e18
        router1.setPrice(address(usdc), 1e18);
        router1.setPrice(address(weth), 2000e18);
        router1.setPrice(address(wbtc), 30000e18);

        router2.setPrice(address(usdc), 1e18);
        router2.setPrice(address(weth), 1500e18);
        router2.setPrice(address(wbtc), 28000e18);

        lending = new MiniLendingMC_BadDebt_TWAP(
            address(usdc),
            address(router1),
            1e9,        // ratePerSecond, deliberately tiny for tests
            0.1e18,     // reserve factor = 10%
            0.5e18,     // close factor = 50%
            0.1e18,     // liquidation bonus = 10%
            2_000_000e18, // borrow cap
            5_000_000e18  // supply cap
        );

        lending.supportCollateral(address(weth), 0.8e18);
        lending.supportCollateral(address(wbtc), 0.75e18);

        // liquidity provider
        usdc.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        usdc.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);
        vm.stopPrank();

        // alice
        usdc.mint(alice, 50_000e18);
        weth.mint(alice, 100e18);
        wbtc.mint(alice, 10e18);

        vm.startPrank(alice);
        usdc.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        wbtc.approve(address(lending), type(uint256).max);
        vm.stopPrank();

        // bob liquidator
        usdc.mint(bob, 100_000e18);
        weth.mint(bob, 10e18);
        vm.startPrank(bob);
        usdc.approve(address(lending), type(uint256).max);
        weth.approve(address(lending), type(uint256).max);
        vm.stopPrank();
    }

    // =============================================================
    //                        ONLY OWNER TESTS
    // =============================================================

    function test_nonOwnerCannotPause() public {
        vm.prank(attacker);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.NotOwner.selector);
        lending.setPaused(true);
    }

    function test_nonOwnerCannotSetRouter() public {
        vm.prank(attacker);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.NotOwner.selector);
        lending.setOracleRouter(address(router2));
    }

    function test_nonOwnerCannotSetCollateralFactor() public {
        vm.prank(attacker);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.NotOwner.selector);
        lending.setCollateralFactor(address(weth), 0.7e18);
    }

    function test_ownerCanPauseAndUnpause() public {
        lending.setPaused(true);
        assertTrue(lending.paused());

        lending.setPaused(false);
        assertTrue(!lending.paused());
    }

    // =============================================================
    //                     CONFIG SANITY TESTS
    // =============================================================

    function test_setRouterRejectsZeroAddress() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.ZeroAddress.selector);
        lending.setOracleRouter(address(0));
    }

    function test_supportCollateralRejectsDuplicate() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.AlreadySupported.selector);
        lending.supportCollateral(address(weth), 0.8e18);
    }

    function test_supportCollateralRejectsTooHighCF() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidFactor.selector);
        lending.supportCollateral(address(0x1234), 0.99e18);
    }

    function test_setCollateralFactorRejectsUnsupported() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.UnsupportedCollateral.selector);
        lending.setCollateralFactor(address(0x7777), 0.7e18);
    }

    function test_setCollateralFactorRejectsZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidFactor.selector);
        lending.setCollateralFactor(address(weth), 0);
    }

    function test_setLiquidationBonusRejectsTooHigh() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidBonus.selector);
        lending.setLiquidationBonus(0.21e18);
    }

    function test_setReserveFactorRejectsTooHigh() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidReserveFactor.selector);
        lending.setReserveFactor(0.51e18);
    }

    function test_setCloseFactorRejectsZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidCloseFactor.selector);
        lending.setCloseFactor(0);
    }

    function test_setBorrowCapRejectsZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidCap.selector);
        lending.setBorrowCap(0);
    }

    function test_setSupplyCapRejectsZero() public {
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.InvalidCap.selector);
        lending.setSupplyCap(0);
    }

    // =============================================================
    //                        PAUSE MATRIX TESTS
    // =============================================================

    function test_pausedDepositReverts() public {
        lending.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.Paused.selector);
        lending.deposit(100e18);
        vm.stopPrank();
    }

    function test_pausedWithdrawReverts() public {
        vm.startPrank(alice);
        usdc.mint(alice, 1000e18);
        lending.deposit(100e18);
        vm.stopPrank();

        lending.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.Paused.selector);
        lending.withdraw(10e18);
        vm.stopPrank();
    }

    function test_pausedDepositCollateralReverts() public {
        lending.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.Paused.selector);
        lending.depositCollateral(address(weth), 1e18);
        vm.stopPrank();
    }

    function test_pausedWithdrawCollateralReverts() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        vm.stopPrank();

        lending.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.Paused.selector);
        lending.withdrawCollateral(address(weth), 0.1e18);
        vm.stopPrank();
    }

    function test_pausedBorrowReverts() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        vm.stopPrank();

        lending.setPaused(true);

        vm.startPrank(alice);
        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.Paused.selector);
        lending.borrow(500e18);
        vm.stopPrank();
    }

    function test_pausedRepayStillAllowed() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        lending.borrow(500e18);
        vm.stopPrank();

        lending.setPaused(true);

        uint256 debtBefore = lending.debtOf(alice);

        vm.startPrank(alice);
        lending.repay(100e18);
        vm.stopPrank();

        uint256 debtAfter = lending.debtOf(alice);
        assertLt(debtAfter, debtBefore);
    }

    function test_pausedLiquidateStillAllowed() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18); // worth 2000
        lending.borrow(1400e18); // borrowable = 1600, still healthy at start
        vm.stopPrank();

        // 价格下跌 -> unhealthy
        router1.setPrice(address(weth), 1500e18);
        // borrowable = 1500 * 0.8 = 1200 < 1400

        lending.setPaused(true);

        uint256 bobBalBefore = weth.balanceOf(bob);

        vm.startPrank(bob);
        (uint256 actualRepay, uint256 seized) = lending.liquidate(alice, address(weth), 200e18);
        vm.stopPrank();

        assertGt(actualRepay, 0);
        assertGt(seized, 0);
        assertGt(weth.balanceOf(bob), bobBalBefore);
    }

    // =============================================================
    //                    CAP / LIMIT TESTS
    // =============================================================

    function test_supplyCapWorks() public {
        lending.setSupplyCap(500_100e18);

        address extra = address(0x9999);
        usdc.mint(extra, 1000e18);

        vm.startPrank(extra);
        usdc.approve(address(lending), type(uint256).max);

        // 当前已有 500_000e18
        lending.deposit(100e18);

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.SupplyCapExceeded.selector);
        lending.deposit(1e18);
        vm.stopPrank();
    }

    function test_borrowCapWorks() public {
        lending.setBorrowCap(1000e18);

        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);

        lending.borrow(900e18);

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.BorrowCapExceeded.selector);
        lending.borrow(200e18);
        vm.stopPrank();
    }

    // =============================================================
    //                 GOVERNANCE IMPACT / HF TESTS
    // =============================================================

    function test_lowerCollateralFactorLowersHF() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18); // value = 2000
        lending.borrow(1000e18); // debt value = 1000
        vm.stopPrank();

        uint256 hfBefore = lending.healthFactor(alice);
        // borrowable = 2000 * 0.8 = 1600 => HF = 1.6

        lending.setCollateralFactor(address(weth), 0.6e18);

        uint256 hfAfter = lending.healthFactor(alice);
        assertLt(hfAfter, hfBefore);
        // new borrowable = 1200 => HF = 1.2
    }

    function test_routerChangeLowersHF() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18); // price in router1 = 2000
        lending.borrow(1000e18);
        vm.stopPrank();

        uint256 hfBefore = lending.healthFactor(alice);

        lending.setOracleRouter(address(router2)); // weth price now = 1500

        uint256 hfAfter = lending.healthFactor(alice);
        assertLt(hfAfter, hfBefore);
    }

    function test_configChangeDoesNotDirectlyChangeCash() public {
        uint256 cashBefore = lending.cash();

        lending.setCollateralFactor(address(weth), 0.7e18);
        lending.setCloseFactor(0.4e18);
        lending.setLiquidationBonus(0.05e18);
        lending.setOracleRouter(address(router2));

        uint256 cashAfter = lending.cash();
        assertEq(cashAfter, cashBefore);
    }

    function test_configChangeDoesNotDirectlyChangeTotalDebtShares() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1000e18);
        vm.stopPrank();

        uint256 sharesBefore = lending.totalDebtShares();

        lending.setCollateralFactor(address(weth), 0.7e18);
        lending.setCloseFactor(0.4e18);
        lending.setLiquidationBonus(0.05e18);
        lending.setOracleRouter(address(router2));

        uint256 sharesAfter = lending.totalDebtShares();
        assertEq(sharesAfter, sharesBefore);
    }

    function test_configChangeDoesNotDirectlyChangeUserCollateralBalance() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 3e18);
        vm.stopPrank();

        uint256 balBefore = lending.collateralBalanceOf(alice, address(weth));

        lending.setCollateralFactor(address(weth), 0.65e18);
        lending.setOracleRouter(address(router2));

        uint256 balAfter = lending.collateralBalanceOf(alice, address(weth));
        assertEq(balAfter, balBefore);
    }

    // =============================================================
    //                    INTEREST / INDEX TESTS
    // =============================================================

    function test_borrowIndexMonotonicAfterAccrue() public {
        uint256 beforeIdx = lending.borrowIndex();
        vm.warp(block.timestamp + 3 days);
        lending.accrueInterest();
        uint256 afterIdx = lending.borrowIndex();

        assertGe(afterIdx, beforeIdx);
    }

    function test_rateChangeAffectsFutureAccrualNotImmediateDebtShares() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 2e18);
        lending.borrow(1000e18);
        vm.stopPrank();

        uint256 sharesBefore = lending.debtSharesOf(alice);
        uint256 debtBefore = lending.debtOf(alice);

        lending.setRatePerSecond(2e9);

        uint256 sharesAfter = lending.debtSharesOf(alice);
        uint256 debtAfterImmediate = lending.debtOf(alice);

        assertEq(sharesAfter, sharesBefore);
        assertEq(debtAfterImmediate, debtBefore);

        vm.warp(block.timestamp + 1 days);
        lending.accrueInterest();

        uint256 debtAfterTime = lending.debtOf(alice);
        assertGt(debtAfterTime, debtAfterImmediate);
    }

    // =============================================================
    //                       LIQUIDATION / BAD DEBT
    // =============================================================

    function test_realizeBadDebtOnlyWhenNoCollateralLeft() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18);
        lending.borrow(500e18);
        vm.stopPrank();

        vm.expectRevert(MiniLendingMC_BadDebt_TWAP.CollateralStillExists.selector);
        lending.realizeBadDebt(alice);
    }

    function test_liquidationWorksAfterGovernanceRiskChange() public {
        vm.startPrank(alice);
        lending.depositCollateral(address(weth), 1e18); // 2000
        lending.borrow(1200e18); // HF initially = 1600/1200 = 1.333...
        vm.stopPrank();

        // 降 cf 让仓位变不健康
        lending.setCollateralFactor(address(weth), 0.55e18);
        // borrowable = 1100 < 1200 => unhealthy

        uint256 hf = lending.healthFactor(alice);
        assertLt(hf, 1e18);

        vm.startPrank(bob);
        (uint256 actualRepay, uint256 seized) = lending.liquidate(alice, address(weth), 300e18);
        vm.stopPrank();

        assertGt(actualRepay, 0);
        assertGt(seized, 0);
    }




}