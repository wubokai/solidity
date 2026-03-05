// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "../../lib/forge-std/src/StdInvariant.sol";

import {MiniLendingMC_BadDebt} from "../../src/day16/MiniLendingMC_BadDebt.sol";
import {ShareVaultV2Strategy} from "../../src/day16/ShareVaultV2Strategy.sol";

import {CompositeOracle} from "../../src/day16/CompositeOracle.sol";
import {VaultShareOracle} from "../../src/day16/VaultShareOracle.sol";

contract MockERC20 {
    string public name; string public symbol; uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    constructor(string memory n, string memory s) { name=n; symbol=s; }
    function mint(address to, uint256 amt) external { balanceOf[to]+=amt; }
    function approve(address spender, uint256 amt) external returns (bool){ allowance[msg.sender][spender]=amt; return true; }
    function transfer(address to, uint256 amt) external returns (bool){ balanceOf[msg.sender]-=amt; balanceOf[to]+=amt; return true; }
    function transferFrom(address from, address to, uint256 amt) external returns (bool){
        uint256 a=allowance[from][msg.sender]; if(a!=type(uint256).max) allowance[from][msg.sender]=a-amt;
        balanceOf[from]-=amt; balanceOf[to]+=amt; return true;
    }
}

contract Day16_Handler {
    MockERC20 public asset;
    ShareVaultV2Strategy public vault;
    MiniLendingMC_BadDebt public lending;

    constructor(MockERC20 a, ShareVaultV2Strategy v, MiniLendingMC_BadDebt l) {
        asset = a; vault = v; lending = l;
        asset.mint(address(this), 1_000_000e18);
        asset.approve(address(vault), type(uint256).max);
        vault.approve(address(lending), type(uint256).max);
        asset.approve(address(lending), type(uint256).max);
    }

    function act_depositVault(uint256 amt) external {
        uint256 a = bound(amt, 0, 50_000e18);
        if (a == 0) return;
        vault.deposit(a, address(this));
    }

    function act_collateralizeAll() external {
        uint256 s = vault.balanceOf(address(this));
        if (s == 0) return;
        lending.depositCollateral(address(vault), s);
    }

    function act_borrow(uint256 amt) external {
        uint256 a = bound(amt, 0, 10_000e18);
        if (a == 0) return;
        lending.borrow(a);
    }

    function act_repay(uint256 amt) external {
        uint256 a = bound(amt, 0, asset.balanceOf(address(this)));
        if (a == 0) return;
        lending.repay(a);
    }

    function act_withdrawCollateral(uint256 amt) external {
        uint256 a = bound(amt, 0, vault.balanceOf(address(this)));
        if (a == 0) return;
        lending.withdrawCollateral(address(vault), a);
    }

    function act_redeem(uint256 shares) external {
        uint256 s = bound(shares, 0, vault.balanceOf(address(this)));
        if (s == 0) return;
        vault.redeem(s, address(this), address(this));
    }

    function bound(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }
}

contract Day16_ComboInvariant is StdInvariant, Test {
    MockERC20 asset;
    ShareVaultV2Strategy vault;
    MiniLendingMC_BadDebt lending;

    CompositeOracle oracle;
    VaultShareOracle shareOracle;

    Day16_Handler handler;

    function setUp() external {
        asset = new MockERC20("USD","USD");
        vault = new ShareVaultV2Strategy(address(asset),"SV","SV");
        oracle = new CompositeOracle();
        oracle.setStaticPrice(address(asset), 1e18);
        shareOracle = new VaultShareOracle(address(vault),address(oracle));
        oracle.setOracle(address(vault), address(shareOracle));

        lending = new MiniLendingMC_BadDebt(address(asset),address(oracle),0,0);
        lending.listCollateral(address(vault), true);

        asset.mint(address(this),1_000_000e18);
        asset.approve(address(lending), type(uint256).max);
        lending.deposit(500_000e18);

        handler = new Day16_Handler(asset,vault,lending);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = Day16_Handler.act_depositVault.selector;
        selectors[1] = Day16_Handler.act_collateralizeAll.selector;
        selectors[2] = Day16_Handler.act_borrow.selector;
        selectors[3] = Day16_Handler.act_repay.selector;
        selectors[4] = Day16_Handler.act_withdrawCollateral.selector;
        selectors[5] = Day16_Handler.act_redeem.selector;
        
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_vault_totalAssets_covers_cash() external view {
        uint256 cash = asset.balanceOf(address(vault));
        assertGe(vault.totalAssets(),cash);
    }


}