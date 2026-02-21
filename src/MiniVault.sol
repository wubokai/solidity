// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract MiniVault is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    error ZeroAssets();
    error ZeroShares();
    error InsufficientShares();
    error NoAllowanceYet(); 
    error InsufficientAllowance();

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);

    IERC20 public immutable asset;

    constructor(
        IERC20 _asset,
        string memory shareName_,
        string memory shareSymbol_
    ) ERC20(shareName_, shareSymbol_) Ownable(msg.sender) {
        asset = _asset;
    }

    function totalAssets() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // deposit: DOWN
    function convertToShares(uint256 assets) public view returns (uint256 shares) {
        if (assets == 0) return 0;

        uint256 S = totalSupply();
        uint256 A = totalAssets();

        if (S == 0 || A == 0) return assets;

        shares = Math.mulDiv(assets, S, A, Math.Rounding.Floor);
    }

    // assets from shares: DOWN
    function convertToAssets(uint256 shares) public view returns (uint256 assetsOut) {
        if (shares == 0) return 0;

        uint256 S = totalSupply();
        uint256 A = totalAssets();

        if (S == 0) return 0;

        assetsOut = Math.mulDiv(shares, A, S, Math.Rounding.Floor);
    }

    // withdraw preview: UP
    function previewWithdraw(uint256 assets) public view returns (uint256 sharesNeeded) {
        if (assets == 0) return 0;

        uint256 S = totalSupply();
        uint256 A = totalAssets();

        if (S == 0 || A == 0) return 0;

        sharesNeeded = Math.mulDiv(assets, S, A, Math.Rounding.Ceil);
    }

    function deposit(uint256 assets, address receiver)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAssets();

        shares = convertToShares(assets);
        if (shares == 0) revert ZeroShares();

        asset.safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner_)
        external
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (assets == 0) revert ZeroAssets();

        sharesBurned = previewWithdraw(assets);
        if (sharesBurned == 0) revert ZeroShares();

        if (balanceOf(owner_) < sharesBurned) revert InsufficientShares();

       
        // If caller is not the owner, spend share allowance (ERC20 allowance of shares)
        if (owner_ != msg.sender) {
            uint256 allowed = allowance(owner_, msg.sender);
            if (allowed < sharesBurned) revert InsufficientAllowance();

            // Decrease allowance unless it's infinite
            if (allowed != type(uint256).max) {
             _approve(owner_, msg.sender, allowed - sharesBurned);
            }
        }

     
        _burn(owner_, sharesBurned);
        asset.safeTransfer(receiver, assets);

        emit Withdraw(msg.sender, receiver, owner_, assets, sharesBurned);
    }

    function skim() external view returns (uint256) {
        return totalAssets();
    }
}
