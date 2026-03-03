// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../day13/ERC20.sol";
import "../day13/Math.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {IStrategy} from "./IStrategy.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract ShareVaultV2Strategy is ERC20, ReentrancyGuard {
    using Math for uint256;

    IERC20 public immutable asset;

    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    // strategy
    IStrategy public strategy;
    address public owner;
    address public keeper;

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    event StrategySet(address indexed strategy);
    event KeeperSet(address indexed keeper);
    event Invest(uint256 assets);
    event Pull(uint256 requested, uint256 received);

    error ZeroAmount();
    error Slippage();
    error Allowance();

    error NotOwner();
    error NotKeeperOrOwner();
    error BadStrategyAsset();
    error InsufficientLiquidity(); // strategy can't return enough

    modifier onlyOwner(){
        if(msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner && msg.sender != keeper) revert NotKeeperOrOwner();
        _;
    }

    constructor (IERC20 _asset, string memory n, string memory s) ERC20(n, s, _asset.decimals()){
        asset = _asset;
        owner = msg.sender;
        keeper = msg.sender;
    }

    function setKeeper(address k) external onlyOwner {
        keeper = k;
        emit KeeperSet(k);
    }

    function setStrategy(address s) external onlyOwner{
        
    }
}