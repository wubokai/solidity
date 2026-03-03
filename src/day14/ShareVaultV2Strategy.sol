// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC20.sol";
import "../day13/Math.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {IStrategy} from "./IStrategy.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract ShareVaultV2Strategy is ERC20, ReentrancyGuard {
    using Math for uint256;

    IERC20Like public immutable asset;

    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    // strategy
    IStrategy public strategy;
    address public owner;
    address public keeper;

    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

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

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyKeeperOrOwner() {
        if (msg.sender != owner && msg.sender != keeper)
            revert NotKeeperOrOwner();
        _;
    }

    constructor(
        address _asset,
        string memory n,
        string memory s
    ) ERC20(n, s, IERC20Like(_asset).decimals()) {
        asset = IERC20Like(_asset);
        owner = msg.sender;
        keeper = msg.sender;
    }

    function setKeeper(address k) external onlyOwner {
        keeper = k;
        emit KeeperSet(k);
    }

    function setStrategy(address s) external onlyOwner {
        if (s != address(0)) {
            if (IStrategy(s).asset() != address(asset))
                revert BadStrategyAsset();
        }
        strategy = IStrategy(s);
        emit StrategySet(s);
    }

    function cashAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function strategyAssets() public view returns (uint256) {
        address s = address(strategy);
        return s == address(0) ? 0 : strategy.totalAssets();
    }

    function totalAssets() public view returns (uint256) {
        return cashAssets() + strategyAssets();
    }

    function convertToShares(uint256 assets_) public view returns (uint256) {
        return
            Math.mulDivDown(
                assets_,
                totalSupply + VIRTUAL_SHARES,
                totalAssets() + VIRTUAL_ASSETS
            );
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return
            Math.mulDivDown(
                shares,
                totalAssets() + VIRTUAL_ASSETS,
                totalSupply + VIRTUAL_SHARES
            );
    }

    function previewDeposit(uint256 assets_) public view returns (uint256) {
        return convertToShares(assets_); // down
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return
            Math.mulDivUp(
                shares,
                totalAssets() + VIRTUAL_ASSETS,
                totalSupply + VIRTUAL_SHARES
            ); // up
    }

    function previewWithdraw(uint256 assets_) public view returns (uint256) {
        return
            Math.mulDivUp(
                assets_,
                totalSupply + VIRTUAL_SHARES,
                totalAssets() + VIRTUAL_ASSETS
            ); // up
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares); // down
    }

    function maxDeposit(address) public pure returns (uint256) {
        return type(uint256).max;
    }
    function maxMint(address) public pure returns (uint256) {
        return type(uint256).max;
    }
    function maxWithdraw(address owner_) public view returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }
    function maxRedeem(address owner_) public view returns (uint256) {
        return balanceOf[owner_];
    }

    function invest(
        uint256 assets_
    ) external onlyKeeperOrOwner nonReentrant returns (uint256 deployed) {
        address s = address(strategy);
        if (s == address(0) || assets_ == 0) return 0;

        uint256 cash = cashAssets();
        deployed = assets_ > cash ? cash : assets_;
        if (deployed == 0) return 0;

        require(asset.transfer(s, deployed), "T");
        strategy.deposit(deployed);
        emit Invest(deployed);
    }

    function withdrawFromStrategy(
        uint256 assets_
    ) public onlyKeeperOrOwner nonReentrant returns (uint256 received) {
        address s = address(strategy);
        if (s == address(0) || assets_ == 0) return 0;
        received = strategy.withdraw(assets_, address(this));
        emit Pull(assets_, received);
    }

    function deposit(
        uint256 assets_,
        address receiver
    ) external nonReentrant returns (uint256 shares) {
        shares = _deposit(msg.sender, receiver, assets_);
    }

    function deposit(
        uint256 assets_,
        address receiver,
        uint256 minShares
    ) external nonReentrant returns (uint256 shares) {
        shares = _deposit(msg.sender, receiver, assets_);
        if (shares < minShares) revert Slippage();
    }

    function _deposit(
        address caller,
        address receiver,
        uint256 assets_
    ) internal returns (uint256 shares) {
        if (assets_ == 0) revert ZeroAmount();

        shares = previewDeposit(assets_);
        if (shares == 0) revert Slippage();
        require(asset.transferFrom(caller, address(this), assets_), "T");
        _mint(receiver, shares);
        emit Deposit(caller, receiver, assets_, shares);
    }

    function mint(
        uint256 shares,
        address receiver
    ) external nonReentrant returns (uint256 assets_) {
        assets_ = _mintShares(msg.sender, receiver, shares);
    }

    function mint(
        uint256 shares,
        address receiver,
        uint256 maxAssets
    ) external nonReentrant returns (uint256 assets_) {
        assets_ = _mintShares(msg.sender, receiver, shares);
        if (assets_ > maxAssets) revert Slippage();
    }

    function _mintShares(
        address caller,
        address receiver,
        uint256 shares
    ) internal returns (uint256 assets_) {
        if (shares == 0) revert ZeroAmount();
        assets_ = previewMint(shares);
        if (assets_ == 0) revert Slippage();

        require(asset.transferFrom(caller, address(this), assets_), "TF");
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets_, shares);
    }

    function withdraw(
        uint256 assets_,
        address receiver,
        address owner_
    ) external nonReentrant returns (uint256 shares) {
        shares = _withdraw(msg.sender, receiver, owner_, assets_);
    }

    function withdraw(
        uint256 assets_,
        address receiver,
        address owner_,
        uint256 maxShares
    ) external nonReentrant returns (uint256 shares) {
        shares = _withdraw(msg.sender, receiver, owner_, assets_);
        if (shares > maxShares) revert Slippage();
    }

    function _withdraw(
        address caller,
        address receiver,
        address owner_,
        uint256 assets_
    ) internal returns (uint256 shares) {
        if (assets_ == 0) revert ZeroAmount();

        shares = previewWithdraw(assets_);
        if (shares == 0) revert Slippage();

        _spendAllowanceIfNeeded(owner_, caller, shares);
        _burn(owner_, shares);
        _ensureLiquidity(assets_);
        require(asset.transfer(receiver, assets_), "T");
        emit Withdraw(caller, receiver, owner_, assets_, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_
    ) external nonReentrant returns (uint256 assets_) {
        assets_ = _redeem(msg.sender, receiver, owner_, shares);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner_,
        uint256 minAssets
    ) external nonReentrant returns (uint256 assets_) {
        assets_ = _redeem(msg.sender, receiver, owner_, shares);
        if (assets_ < minAssets) revert Slippage();
    }

    function _redeem(
        address caller,
        address receiver,
        address owner_,
        uint256 shares
    ) internal returns (uint256 assets_) {
        if (shares == 0) revert ZeroAmount();
        assets_ = previewRedeem(shares);
        if (assets_ == 0) revert Slippage();

        _spendAllowanceIfNeeded(owner_, caller, shares);
        _burn(owner_, shares);
        _ensureLiquidity(assets_);

        require(asset.transfer(receiver, assets_), "T");
        emit Withdraw(caller, receiver, owner_, assets_, shares);
    }

    function _ensureLiquidity(uint256 need) internal {
        uint256 cash = cashAssets();
        if (cash >= need) return;

        address s = address(strategy);
        if (s == address(0)) revert InsufficientLiquidity();

        uint256 shortfall = need - cash;

        // pull as much as needed (strategy may return less)
        uint256 got = strategy.withdraw(shortfall, address(this));
        if (cash + got < need) revert InsufficientLiquidity();
    }

    function _spendAllowanceIfNeeded(
        address owner_,
        address spender,
        uint256 shares
    ) internal {
        if (spender == owner_) return;

        uint256 a = allowance[owner_][spender];
        if (a != type(uint256).max) {
            if (a < shares) revert Allowance();
            allowance[owner_][spender] = a - shares;
            emit Approval(owner_, spender, allowance[owner_][spender]);
        }
    }
}
