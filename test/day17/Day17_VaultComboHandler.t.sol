// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";

import {ERC20} from "../../src/day17/ERC20.sol";
import {MiniLendingMC_BadDebt} from "../../src/day17/MiniLendingMC_BadDebt.sol";
import {ShareVaultV2Strategy} from "../../src/day17/ShareVaultV2Strategy.sol";
import {MockStrategy} from "../../src/day17/MockStrategy.sol"; 

contract Day17_VaultComboHandler is Test {
    address[] public actors;

    ERC20 public underlying;
    ERC20 public stable;
    ShareVaultV2Strategy public vault;
    MockStrategy public strategy;
    MiniLendingMC_BadDebt public lending;

    constructor(
        address _underlying,
        address _stable,
        address _vault,
        address _strategy,
        address _lending
    ) {
        underlying = ERC20(_underlying);
        stable = ERC20(_stable);
        vault = ShareVaultV2Strategy(_vault);
        strategy = MockStrategy(_strategy);
        lending = MiniLendingMC_BadDebt(_lending);

        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function depositToVault(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        amount = bound(amount, 1e6, 1_000e18);

        // 这里要求 underlying 有 mint；如果你的 token 类型是 MockERC20，就把 ERC20 改成 MockERC20
        try this._mintUnderlying(user, amount) {} catch {
            return;
        }

        vm.startPrank(user);
        try underlying.approve(address(vault), amount) {} catch {
            vm.stopPrank();
            return;
        }

        try vault.deposit(amount, user) {} catch {}
        vm.stopPrank();
    }

    function depositVaultSharesAsCollateral(uint256 actorSeed, uint256 shareAmount) external {
        address user = _actor(actorSeed);
        uint256 bal = vault.balanceOf(user);
        if (bal == 0) return;

        shareAmount = bound(shareAmount, 1, bal);

        vm.startPrank(user);
        vault.approve(address(lending), shareAmount);
        try lending.depositCollateral(address(vault), shareAmount) {} catch {}
        vm.stopPrank();
    }

    function borrowStable(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);
        amount = bound(amount, 1, 10_000e18);

        vm.prank(user);
        try lending.borrow(amount) {} catch {}
    }

    function repayStable(uint256 actorSeed, uint256 amount) external {
        address user = _actor(actorSeed);

        uint256 debt = lending.debtOf(user);
        if (debt == 0) return;

        amount = bound(amount, 1, debt);

        try this._mintStable(user, amount) {} catch {
            return;
        }

        vm.startPrank(user);
        stable.approve(address(lending), amount);
        try lending.repay(amount) {} catch {}
        vm.stopPrank();
    }

    function donateToVault(uint256 amount) external {
        amount = bound(amount, 1, 500e18);

        address donor = address(0x11);
        try this._mintUnderlying(donor, amount) {} catch {
            return;
        }

        vm.prank(donor);
        try underlying.transfer(address(vault), amount) {} catch {}
    }

    function investCash(uint256 amount) external {
        uint256 cash = vault.cashAssets();
        if (cash == 0) return;

        amount = bound(amount, 1, cash);
        try vault.invest(amount) {} catch {}
    }

    function simulateLoss(uint256 amount) external {
        amount = bound(amount, 1, 500e18);
        try strategy.simulateLoss(address(0xBEEF), amount) {} catch {}
    }

    function liquidate(uint256 actorSeed, uint256 repayAmount) external {
        address user = _actor(actorSeed);
        repayAmount = bound(repayAmount, 1, 10_000e18);

        address liq = address(0x12);

        try this._mintStable(liq, repayAmount) {} catch {
            return;
        }

        vm.startPrank(liq);
        stable.approve(address(lending), repayAmount);
        try lending.liquidate(user, address(vault), repayAmount) {} catch {}
        vm.stopPrank();
    }

    function warp(uint256 dt) external {
        dt = bound(dt, 1, 30 days);
        vm.warp(block.timestamp + dt);
        try lending.accrueInterest() {} catch {}
    }

    // ===== external self-call helpers =====
    function _mintUnderlying(address to, uint256 amount) external {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", to, amount);
        (bool ok,) = address(underlying).call(data);
        require(ok, "mint underlying failed");
    }

    function _mintStable(address to, uint256 amount) external {
        bytes memory data = abi.encodeWithSignature("mint(address,uint256)", to, amount);
        (bool ok,) = address(stable).call(data);
        require(ok, "mint stable failed");
    }
}