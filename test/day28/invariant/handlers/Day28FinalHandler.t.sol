// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../../../lib/forge-std/src/Test.sol";
import "../../../../src/day28/MiniLendingMC_BadDebt_TWAP_Day27.sol";
import "../../../../src/day28/mocks/MockERC20.sol";
import "../../../../src/day28/mocks/FixedPriceOracle.sol";

contract Day28FinalHandler is Test {

    MiniLendingMC_BadDebt_TWAP_Day27 public lending;
    MockERC20 public stable;
    MockERC20 public weth;
    FixedPriceOracle public stableOracle;
    FixedPriceOracle public wethOracle;

    address[] public actors;

    uint256 public constant WAD = 1e18;

    constructor(
        MiniLendingMC_BadDebt_TWAP_Day27 _lending,
        MockERC20 _stable,
        MockERC20 _weth,
        FixedPriceOracle _stableOracle,
        FixedPriceOracle _wethOracle
    ) {
        lending = _lending;
        stable = _stable;
        weth = _weth;
        stableOracle = _stableOracle;
        wethOracle = _wethOracle;

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA1));
        actors.push(address(0xD0D));
        actors.push(address(0xE11));

        uint256 seedStable = 5_000_000e18;
        uint256 seedWeth = 5_000e18;

        for (uint256 i = 0; i < actors.length; i++) {
            stable.mint(actors[i], seedStable);
            weth.mint(actors[i], seedWeth);

            vm.startPrank(actors[i]);
            stable.approve(address(lending), type(uint256).max);
            weth.approve(address(lending), type(uint256).max);
            vm.stopPrank();
        }

    }

    function actorCount() external view returns(uint256){
        return actors.length;
    }

    function getActor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1e6, 50_000e18);

        vm.startPrank(user);
        (bool ok,) = address(lending).call(
            abi.encodeWithSelector(lending.deposit.selector, amount)
        );
        ok;
        vm.stopPrank();

    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);

        uint256 bal = lending.depositOf(user);
        if (bal == 0) return;
        uint256 amount = bound(amountSeed, 1, bal);
    
        vm.startPrank(user);
        (bool ok, ) = address(lending).call(
            abi.encodeWithSelector(lending.withdraw.selector, amount)
        );
        ok;
        vm.stopPrank();

    }

    function depositCollateral(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 amount = bound(amountSeed,1e12, 20e18);


        vm.startPrank(user);
        (bool ok, ) = address(lending).call(
            abi.encodeWithSelector(
                lending.depositCollateral.selector,
                address(weth),
                amount
            )
        );
        ok;
        vm.stopPrank();

    }

    function withdrawCollateral(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 bal = lending.collateralBalanceOf(user, address(weth));
        if(bal == 0) return;

        vm.startPrank(user);
        uint256 amount = bound(amountSeed, 1, bal);
        (bool ok, )  = address(lending).call(
            abi.encodeWithSelector(
                lending.withdrawCollateral.selector,
                address(weth),
                amount
            )
        );
        ok;
        vm.stopPrank();
    }

    function borrow(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1e6, 20_000e18);

        vm.startPrank(user);
        (bool ok, ) = address(lending).call(
            abi.encodeWithSelector(lending.borrow.selector, amount)
        );
        ok;
        vm.stopPrank();
    }

    function repay(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 debt = lending.debtOf(user);
        if(debt == 0) return;

        uint256 amount = bound(amountSeed,1, debt + 100e18);
        vm.startPrank(user);
        (bool ok, ) = address(lending).call(
            abi.encodeWithSelector(lending.repay.selector, amount)
        );
        ok;
        vm.stopPrank();
    }

    function liquidate(
        uint256 liquidatorSeed,
        uint256 victimSeed,
        uint256 repayAmountSeed
    ) external {
        address liquidator = _actor(liquidatorSeed);
        address victim = _actor(victimSeed);
        if (liquidator == victim) return;

        uint256 debt = lending.debtOf(victim);
        if (debt == 0) return;

        uint256 repayAmount = bound(repayAmountSeed, 1, debt + 100e18);
        vm.startPrank(liquidator);
        (bool ok, ) = address(lending).call(
            abi.encodeWithSelector(
                lending.liquidate.selector,
                victim,
                address(weth),
                repayAmount
            )
        );
        ok;
        vm.stopPrank();

    }

    function warp(uint256 dtSeed) external {
        uint256 dt = bound(dtSeed, 1, 7 days);
        vm.warp(block.timestamp + dt);
    }

    function accrue() external {
        lending.accrueInterest();
    }

    function setWethPrice(uint256 priceSeed) external {
        uint256 newPrice = bound(priceSeed, 100e18, 5_000e18);
        wethOracle.setPrice(address(weth), newPrice);
    }

    function setStablePrice(uint256 priceSeed) external {
        uint256 newPrice = bound(priceSeed, 0.90e18, 1.10e18);
        stableOracle.setPrice(address(stable), newPrice);
    }

    function donateStableToPool(uint256 actorSeed, uint256 amountSeed) external {
        address user = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1e6, 5_000e18);

        vm.prank(user);
        stable.transfer(address(lending), amount);
    }

    function sumDepositOfActors() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += lending.depositOf(actors[i]);
        }
    }

    function sumDebtSharesOfActors() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += lending.debtSharesOf(actors[i]);
        }
    }

    function sumWethCollateralOfActors() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i++) {
            sum += lending.collateralBalanceOf(actors[i], address(weth));
        }
    }

    function countUnderwaterActors() external view returns (uint256 n) {
        for (uint256 i = 0; i < actors.length; i++) {
            if (
                lending.debtOf(actors[i]) > 0 &&
                lending.healthFactor(actors[i]) < lending.WAD()
            ) {
                n++;
            }
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

}
