// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../lib/forge-std/src/Test.sol";
import "./VaultAdapter.t.sol";

contract MockERC20 is IERC20Like {

    string public name;
    string public symbol;
    uint8 public immutable override decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockStrategy is IStrategyLike {
    
    address public immutable override asset;
    IERC20Like internal immutable token;

    // 用“口径层”模拟损失：totalAssets = rawBal * (1-lossBps) + virtualProfit
    uint256 public lossBps;      // 0..10000
    uint256 public virtualProfit;

    constructor(IERC20Like a) {
        token = a;
        asset = address(a);
    }

    function setLossBps(uint256 bps) external {
        require(bps <= 10_000, "bps");
        lossBps = bps;
    }

    function addVirtualProfit(uint256 amount) external {
        virtualProfit += amount;
    }

    function totalAssets() public view override returns (uint256) {
        uint256 bal = token.balanceOf(address(this));
        uint256 afterLoss = bal - (bal * lossBps / 10_000);
        return afterLoss + virtualProfit;
    }

    function deposit(uint256 assets_) external override returns (uint256) {
        // Vault already transferred `assets_` to strategy before calling deposit.
        // Keep this as a no-op so tests model the expected push-flow integration.
        return assets_;
    }

    function withdraw(uint256 assets_, address receiver) external override returns (uint256 received) {
        uint256 bal = token.balanceOf(address(this));
        received = assets_ <= bal ? assets_ : bal; // partial allowed
        require(token.transfer(receiver, received), "T");
    }
}
