// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./VaultAdapter.t.sol";

contract VaultStrategyHandler is Test {
    VaultAdapter public A;
    IERC20Like public asset;
    address public keeperOrOwner; // 用于调用 invest/pull（你 vault 里 onlyKeeperOrOwner）

    address[] public users;
    uint256 public ghostDonated;

    constructor(VaultAdapter adapter, address keeper_, address[] memory _users) {
        A = adapter;
        asset = adapter.asset();
        keeperOrOwner = keeper_;
        users = _users;
    }

    function _user(uint256 seed) internal view returns (address) {
        return users[seed % users.length];
    }

    function _boundAmt(uint256 x, uint256 min, uint256 max) internal pure returns (uint256) {
        if (max < min) return min;
        if (x < min) return min;
        if (x > max) return max;
        return x;
    }

    // ---- actions ----
    function act_deposit(uint256 userSeed, uint256 amtSeed) external {
        address u = _user(userSeed);
        uint256 bal = asset.balanceOf(u);
        if (bal == 0) return;
        uint256 amt = _boundAmt(amtSeed, 1, bal);
        try A.deposit(u, amt, u) {} catch {}
    }

    function act_mint(uint256 userSeed, uint256 shareSeed) external {
        address u = _user(userSeed);
        uint256 need = A.vault().previewMint(shareSeed);
        if (need == 0) return;
        uint256 bal = asset.balanceOf(u);
        if (bal == 0) return;

        // 如果 need > bal，缩 shares
        if (need > bal) {
            uint256 maxShares = A.vault().convertToShares(bal);
            if (maxShares == 0) return;
            shareSeed = _boundAmt(shareSeed, 1, maxShares);
        } else {
            if (shareSeed == 0) shareSeed = 1;
        }

        try A.mint(u, shareSeed, u) {} catch {}
    }

    function act_withdraw(uint256 userSeed, uint256 amtSeed) external {
        address u = _user(userSeed);
        uint256 maxA = A.vault().maxWithdraw(u);
        if (maxA == 0) return;
        uint256 amt = _boundAmt(amtSeed, 1, maxA);
        try A.withdraw(u, amt, u, u) {} catch {}
    }

    function act_redeem(uint256 userSeed, uint256 shareSeed) external {
        address u = _user(userSeed);
        uint256 sh = A.vault().balanceOf(u);
        if (sh == 0) return;
        uint256 shares = _boundAmt(shareSeed, 1, sh);
        try A.redeem(u, shares, u, u) {} catch {}
    }

    function act_invest(uint256 amtSeed) external {
        uint256 cash = A.cash();
        if (cash == 0) return;
        uint256 amt = _boundAmt(amtSeed, 1, cash);
        try A.invest(keeperOrOwner, amt) {} catch {}
    }

    function act_pull(uint256 amtSeed) external {
        IStrategyLike s = A.strategy();
        uint256 sa = s.totalAssets();
        if (sa == 0) return;
        uint256 amt = _boundAmt(amtSeed, 1, sa);
        try A.pull(keeperOrOwner, amt) {} catch {}
    }

    function act_donate(uint256 donorSeed, uint256 amtSeed) external {
        address d = _user(donorSeed);
        uint256 bal = asset.balanceOf(d);
        if (bal == 0) return;
        uint256 amt = _boundAmt(amtSeed, 1, bal);

        vm.startPrank(d);
        (bool ok) = asset.transfer(address(A.vault()), amt);
        ok;
        vm.stopPrank();

        ghostDonated += amt;
    }

    function act_warp(uint256 secSeed) external {
        uint256 dt = _boundAmt(secSeed, 0, 3 days);
        vm.warp(block.timestamp + dt);
    }
}