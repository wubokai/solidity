// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {ShareVaultV2Strategy} from "../../src/day14/ShareVaultV2Strategy.sol";
import {MockStrategy} from "../../src/day14/MockStrategy.sol";
import {MockERC20} from "./MockERC20.sol";
import {StrategyV0Handler} from "./StrategyV0Handler.sol";

contract StrategyV0Invariant is StdInvariant, Test {
    MockERC20 token;
    ShareVaultV2Strategy vault;
    MockStrategy strat;

    StrategyV0Handler handler;

    address alice = address(0xA11CE);
    address bob   = address(0xB0B);
    address carol = address(0x11);

    function setUp() external {
        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV2", "SV2");
        strat = new MockStrategy(address(token), address(vault));
        vault.setStrategy(address(strat));

        // mint to actors
        token.mint(alice, 50_000e18);
        token.mint(bob,   50_000e18);
        token.mint(carol, 50_000e18);

        // mint to invariant/handler so donate actions can work
        token.mint(address(this), 50_000e18);

        address [] memory actors = new address[](3);
        actors[0] = alice;
        actors[1] = bob;
        actors[2] = carol;

        handler = new StrategyV0Handler(address(vault), address(strat), actors);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.actDeposit.selector;
        selectors[1] = handler.actWithdraw.selector;
        selectors[2] = handler.actInvest.selector;
        selectors[3] = handler.actDonateToVault.selector;
        selectors[4] = handler.actDonateToStrategy.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalAssets_equals_cash_plus_strategy() external view {
        uint256 ta = vault.totalAssets();
        uint256 cash = vault.cashAssets();
        uint256 stratAssets = vault.strategyAssets();

        // rounding should be exact here
        assertEq(ta, cash + stratAssets);
    }

    function invariant_no_negative_balances_sanity() external view {
        // not super meaningful but catches underflows in mocks
        assertGe(token.balanceOf(address(vault)), 0);
        assertGe(token.balanceOf(address(strat)), 0);
    }
}