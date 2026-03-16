// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../../lib/forge-std/src/Test.sol";

import {MiniAMM, IERC20Like} from "../../src/day22/MiniAMM.sol";
import {SimpleTWAPOracle} from "../../src/day22/SimpleTWAPOracle.sol";
import {FlashLoanMock} from "../../src/day22/FlashLoanMock.sol";


import {MockERC20} from "../../src/day22/MockERC20.sol";
import {RepayOnlyReceiverMock} from "../../src/day22/RepayOnlyReceiverMock.sol";
import {NoRepayReceiverMock} from "../../src/day22/NoRepayReceiverMock.sol";
import {AMMPriceManipulationReceiver} from "../../src/day22/AMMPriceManipulationReceiver.sol";

contract Day22FlashLoanManipulationTest is Test {
    uint256 internal constant E18 = 1e18;

    MockERC20 internal token0;
    MockERC20 internal token1;

    MiniAMM internal amm;
    SimpleTWAPOracle internal oracle;
    FlashLoanMock internal lender;

    address internal lp = address(0xA11CE);
    address internal user = address(0xB0B);

    function setUp() public {
        token0 = new MockERC20("Token0", "TK0");
        token1 = new MockERC20("Token1", "TK1");

        amm = new MiniAMM(IERC20Like(address(token0)), IERC20Like(address(token1)));
        lender = new FlashLoanMock();

        _seedAMM();
        oracle = new SimpleTWAPOracle(address(amm));
    }

    function test_flashLoan_repay_success() public {
        RepayOnlyReceiverMock receiver = new RepayOnlyReceiverMock();

        token0.mint(address(lender), 1_000 * E18);

        uint256 lenderBefore = token0.balanceOf(address(lender));

        lender.flashLoan(address(receiver), address(token0), 100 * E18, "");

        uint256 lenderAfter = token0.balanceOf(address(lender));
        assertEq(lenderAfter, lenderBefore, "lender balance should be unchanged");
    }

    function test_flashLoan_notRepaid_reverts() public {
        NoRepayReceiverMock receiver = new NoRepayReceiverMock();

        token0.mint(address(lender), 1_000 * E18);

        vm.expectRevert(FlashLoanMock.NotRepaid.selector);
        lender.flashLoan(address(receiver), address(token0), 100 * E18, "");
    }

    function test_spotPrice_canBeManipulatedWithinSingleTransaction() public {
        token0.mint(address(lender), 10_000 * E18);

        AMMPriceManipulationReceiver receiver =
            new AMMPriceManipulationReceiver(address(lender), address(amm));

        // prefund receiver with token0 so it can repay after using borrowed token0 to swap
        token0.mint(address(receiver), 1_000 * E18);

        uint256 spotBefore = _spotPrice0();
        assertEq(spotBefore, 1e18, "initial spot should be 1:1");

        AMMPriceManipulationReceiver.Params memory p =
            AMMPriceManipulationReceiver.Params({
                mode: AMMPriceManipulationReceiver.Mode.Swap0For1,
                minOut: 0,
                to: address(receiver),
                deadline: block.timestamp + 1 days
            });

        lender.flashLoan(
            address(receiver),
            address(token0),
            500 * E18,
            abi.encode(p)
        );

        uint256 spotAfter = _spotPrice0();

        assertLt(spotAfter, spotBefore, "spot price should move down after large token0 sell");

        // Rough sanity: with 1000/1000 pool and 500 token0 in,
        // spot should be meaningfully distorted downward.
        assertLt(spotAfter, 0.7e18, "spot should be clearly manipulated");
    }

    function test_twapIsLessDistortedThanSpot_afterSingleShortManipulation() public {
        token0.mint(address(lender), 10_000 * E18);

        AMMPriceManipulationReceiver receiver =
            new AMMPriceManipulationReceiver(address(lender), address(amm));

        // prefund same token so flash loan can be repaid after swap consumes borrowed amount
        token0.mint(address(receiver), 1_000 * E18);

        uint256 fairPrice = 1e18;
        uint256 spotBefore = _spotPrice0();
        assertEq(spotBefore, fairPrice, "initial spot should be 1");

        // Let the pool sit at fair price for a long window first
        vm.warp(block.timestamp + 1 hours);

        // With your current oracle implementation, update() computes average
        // from constructor snapshot up to now.
        oracle.update();
        uint256 twapBefore = oracle.consult(address(token0), 1e18);
        assertApproxEqAbs(twapBefore, fairPrice, 1, "twap before manipulation should be ~1");

        AMMPriceManipulationReceiver.Params memory p =
            AMMPriceManipulationReceiver.Params({
                mode: AMMPriceManipulationReceiver.Mode.Swap0For1,
                minOut: 0,
                to: address(receiver),
                deadline: block.timestamp + 1 days
            });

        lender.flashLoan(
            address(receiver),
            address(token0),
            500 * E18,
            abi.encode(p)
        );

        uint256 spotAfter = _spotPrice0();
        assertLt(spotAfter, fairPrice, "spot should move immediately");

        // Recompute oracle average at the same timestamp after manipulation.
        // Since the manipulation happened only at the tail end of a long prior window,
        // TWAP should remain much closer to fair price than spot does.
        oracle.update();
        uint256 twapAfter = oracle.consult(address(token0), 1e18);

        uint256 spotDistortion = _absDiff(spotAfter, fairPrice);
        uint256 twapDistortion = _absDiff(twapAfter, fairPrice);

        assertLt(
            twapDistortion,
            spotDistortion,
            "TWAP should be less distorted than spot after short manipulation"
        );

        assertGt(twapAfter, spotAfter, "TWAP should remain above manipulated spot");
        assertApproxEqAbs(twapAfter, fairPrice, 1, "TWAP should stay ~1 in this short manipulation demo");
    }

    function _seedAMM() internal {
        token0.mint(lp, 10_000 * E18);
        token1.mint(lp, 10_000 * E18);

        vm.startPrank(lp);
        token0.approve(address(amm), type(uint256).max);
        token1.approve(address(amm), type(uint256).max);

        amm.addLiquidity(
            lp,
            1_000 * E18,
            1_000 * E18,
            1_000 * E18,
            1_000 * E18,
            block.timestamp + 1 days
        );
        vm.stopPrank();
    }

    // spot price of token0 in token1 terms, scaled by 1e18
    function _spotPrice0() internal view returns (uint256) {
        (uint112 r0, uint112 r1, ) = amm.getReserves();
        return (uint256(r1) * 1e18) / uint256(r0);
    }

    function _absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }
}
