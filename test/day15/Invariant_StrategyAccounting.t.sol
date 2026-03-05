// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import "./VaultAdapter.t.sol";
import "./StrategyMocks.t.sol";
import "./VaultStrategyHandler.t.sol";
import {ShareVaultV2Strategy} from "../../src/day15/ShareVaultV2Strategy.sol";

contract Invariant_StrategyAccounting is StdInvariant, Test {
    ShareVaultV2Strategy vault;
    MockERC20 token;
    MockStrategy strategy;

    VaultAdapter A;
    VaultStrategyHandler handler;

    address owner;
    address keeper;

    address[] users;

    function setUp() external {
        owner = address(this); // 这份 setUp 里我们用 test 合约作为 owner
        keeper = address(0xBEEF);

        token = new MockERC20("Mock", "MOCK", 18);
        vault = new ShareVaultV2Strategy(address(token), "SV", "SV");

        // owner 设置 keeper
        vault.setKeeper(keeper);

        // 部署策略并 setStrategy（onlyOwner）
        strategy = new MockStrategy(token);
        vault.setStrategy(address(strategy));

        // seed users
        users = new address[](4);
        users[0] = address(0xA11CE);
        users[1] = address(0xB0B);
        users[2] = address(0xCA11);
        users[3] = address(0xD00D);

        for (uint256 i; i < users.length; i++) {
            token.mint(users[i], 1_000_000e18);
        }

        A = new VaultAdapter(IShareVaultV2StrategyLike(address(vault)));
        handler = new VaultStrategyHandler(A, keeper, users);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.act_deposit.selector;
        selectors[1] = handler.act_mint.selector;
        selectors[2] = handler.act_withdraw.selector;
        selectors[3] = handler.act_redeem.selector;
        selectors[4] = handler.act_invest.selector;
        selectors[5] = handler.act_pull.selector;
        selectors[6] = handler.act_donate.selector;
        selectors[7] = handler.act_warp.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_totalAssets_equals_cash_plus_strategyAssets() external view {
        uint256 ta = vault.totalAssets();
        uint256 cash = token.balanceOf(address(vault));
        uint256 sa = strategy.totalAssets();
        assertEq(ta, cash + sa, "TA != cash + strategy");
    }

    function invariant_preview_consistency_sanity() external view {
        // 轻量 sanity：1 share 对应资产不会超过 totalAssets + 1（避免离谱溢出/除0）
        if (vault.totalSupply() == 0) return;
        uint256 a = vault.convertToAssets(1);
        assertTrue(a <= vault.totalAssets() + 1, "weird convert");
    }

    
}
