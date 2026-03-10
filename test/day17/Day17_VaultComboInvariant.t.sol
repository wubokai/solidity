// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {ERC20} from "../../src/day17/ERC20.sol";
import {MiniLendingMC_BadDebt} from "../../src/day17/MiniLendingMC_BadDebt.sol";
import {ShareVaultV2Strategy} from "../../src/day17/ShareVaultV2Strategy.sol";
import {VaultShareOracle} from "../../src/day17/VaultShareOracle.sol";
import {MockStrategy} from "../../src/day17/MockStrategy.sol";

import {MockOracle} from "./MockOracle.sol";
import {OracleRouterMock} from "./OracleRouterMock.sol";
import {Day17_VaultComboHandler} from "./Day17_VaultComboHandler.t.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint8 d) ERC20(n, s, d) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract Day17_VaultComboInvariant_Test is StdInvariant, Test {
    MockERC20 internal underlying;
    MockERC20 internal stable;

    ShareVaultV2Strategy internal vault;
    MockStrategy internal strategy;

    MockOracle internal baseOracle;
    VaultShareOracle internal vaultShareOracle;
    OracleRouterMock internal routerOracle;

    MiniLendingMC_BadDebt internal lending;
    Day17_VaultComboHandler internal handler;

    function setUp() public {
        underlying = new MockERC20("Underlying", "UND", 18);
        stable = new MockERC20("Stable", "STBL", 18);

        vault = new ShareVaultV2Strategy(address(underlying), "Vault Share", "vSHARE");
        strategy = new MockStrategy(address(underlying), address(vault));
        vault.setStrategy(address(strategy));

        baseOracle = new MockOracle();
        baseOracle.setPrice(address(underlying), 1e18);
        baseOracle.setPrice(address(stable), 1e18);

        vaultShareOracle = new VaultShareOracle(address(vault), address(baseOracle));

        routerOracle = new OracleRouterMock();
        routerOracle.setDirectPrice(address(underlying), 1e18);
        routerOracle.setDirectPrice(address(stable), 1e18);
        routerOracle.setDelegatedOracle(address(vault), address(vaultShareOracle));

        lending = new MiniLendingMC_BadDebt(
            address(stable),
            address(routerOracle),
            0,
            0
        );

        lending.listCollateral(address(vault), true);

        stable.mint(address(this), 1_000_000e18);
        stable.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);

        handler = new Day17_VaultComboHandler(
            address(underlying),
            address(stable),
            address(vault),
            address(strategy),
            address(lending)
        );

        targetContract(address(handler));
    }

    // 1) Vault 总资产口径一致
    function invariant_VaultTotalAssetsEqualsCashPlusStrategyAssets() public view {
        uint256 totalAssets = vault.totalAssets();
        uint256 cash = vault.cashAssets();
        uint256 strat = vault.strategyAssets();

        assertEq(totalAssets, cash + strat);
    }

    // 2) Vault share oracle 不应高估
    function invariant_VaultSharePriceIsConservative() public view {
        uint256 supply = vault.totalSupply();
        uint256 px = vaultShareOracle.price(address(vault));

        if (supply == 0) {
            assertEq(px, 0);
        } else {
            uint256 theoretical = (vault.totalAssets() * 1e18) / supply;
            assertLe(px, theoretical);
        }
    }

    // 3) Lending cash 必须等于 stable 实际余额
    function invariant_LendingCashMatchesStableBalance() public view {
        assertEq(lending.cash(), stable.balanceOf(address(lending)));
    }

    // 4) 坏账不能超过总债务
    function invariant_BadDebtCannotExceedTotalDebt() public view {
        assertLe(lending.badDebt(), lending.totalDebt());
    }
}