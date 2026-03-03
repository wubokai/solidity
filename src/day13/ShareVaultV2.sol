// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./ERC20.sol";
import "./Math.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract ShareVaultV2 is ERC20, ReentrancyGuard{
    using Math for uint256;

    IERC20 public immutable asset;

    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    // ERC4626-style events
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    // Reentrancy guard
    uint256 private _locked = 1;

    error ZeroAmount();
    error Slippage();
    error Allowance();

    constructor(IERC20 _asset, string memory n, string memory s)
        ERC20(n, s, _asset.decimals())
    {
        asset = _asset;
    }

    /*//////////////////////////////////////////////////////////////
                               VIEWS
    //////////////////////////////////////////////////////////////*/

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return Math.mulDivDown(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return Math.mulDivDown(shares, totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES);
    }

    // preview: must match action rounding
    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets); // down
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        return Math.mulDivUp(shares, totalAssets() + VIRTUAL_ASSETS, totalSupply + VIRTUAL_SHARES); // up
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        return Math.mulDivUp(assets, totalSupply + VIRTUAL_SHARES, totalAssets() + VIRTUAL_ASSETS); // up
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares); // down
    }

    function maxDeposit(address) public pure returns (uint256) { return type(uint256).max; }
    function maxMint(address) public pure returns (uint256) { return type(uint256).max; }
    function maxWithdraw(address owner) public view returns (uint256) { return convertToAssets(balanceOf[owner]); }
    function maxRedeem(address owner) public view returns (uint256) { return balanceOf[owner]; }

    /*//////////////////////////////////////////////////////////////
                               ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint256 assets, address receiver) external nonReentrant returns (uint256 shares) {
        shares = _deposit(msg.sender, receiver, assets);
    }

    function deposit(uint256 assets, address receiver, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _deposit(msg.sender, receiver, assets);
        if (shares < minShares) revert Slippage();
    }

    function _deposit(address caller, address receiver, uint256 assets) internal returns (uint256 shares) {
        if (assets == 0) revert ZeroAmount();

        shares = previewDeposit(assets);
        if (shares == 0) revert Slippage();

        require(asset.transferFrom(caller, address(this), assets), "TF");
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assets) {
        assets = _mintShares(msg.sender, receiver, shares);
    }

    function mint(uint256 shares, address receiver, uint256 maxAssets)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _mintShares(msg.sender, receiver, shares);
        if (assets > maxAssets) revert Slippage();
    }

    function _mintShares(address caller, address receiver, uint256 shares) internal returns (uint256 assets) {
        if (shares == 0) revert ZeroAmount();

        assets = previewMint(shares);
        if (assets == 0) revert Slippage();

        require(asset.transferFrom(caller, address(this), assets), "TF");
        _mint(receiver, shares);

        emit Deposit(caller, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _withdraw(msg.sender, receiver, owner, assets);
    }

    function withdraw(uint256 assets, address receiver, address owner, uint256 maxShares)
        external
        nonReentrant
        returns (uint256 shares)
    {
        shares = _withdraw(msg.sender, receiver, owner, assets);
        if (shares > maxShares) revert Slippage();
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets)
        internal
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();

        shares = previewWithdraw(assets);
        if (shares == 0) revert Slippage();

        _spendAllowanceIfNeeded(owner, caller, shares);

        _burn(owner, shares);
        require(asset.transfer(receiver, assets), "T");

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _redeem(msg.sender, receiver, owner, shares);
    }

    function redeem(uint256 shares, address receiver, address owner, uint256 minAssets)
        external
        nonReentrant
        returns (uint256 assets)
    {
        assets = _redeem(msg.sender, receiver, owner, shares);
        if (assets < minAssets) revert Slippage();
    }

    function _redeem(address caller, address receiver, address owner, uint256 shares)
        internal
        returns (uint256 assets)
    {
        if (shares == 0) revert ZeroAmount();

        assets = previewRedeem(shares);
        if (assets == 0) revert Slippage();

        _spendAllowanceIfNeeded(owner, caller, shares);

        _burn(owner, shares);
        require(asset.transfer(receiver, assets), "T");

        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _spendAllowanceIfNeeded(address owner, address spender, uint256 shares) internal {
        if (spender == owner) return;

        uint256 a = allowance[owner][spender];
        if (a != type(uint256).max) {
            if (a < shares) revert Allowance();
            allowance[owner][spender] = a - shares;
            emit Approval(owner, spender, allowance[owner][spender]);
        }
    }
}