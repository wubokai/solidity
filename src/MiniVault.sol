// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;


import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";


contract MiniVault is ERC20, ReentrancyGuard{
    using SafeERC20 for IERC20;

    error ZeroAmount();
    error ZeroShares();
    error ZeroAssets();
    error InsufficientShares();

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    
    
    IERC20 public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public balance;
    address public Owner;

    modifier onlyOwner{
        require(msg.sender == Owner,"not owner");
        _;
    }

    constructor(
        IERC20 _asset,
        string memory shareName_,
        string memory shareSymbol_
    )ERC20(shareName_,shareSymbol_) onlyOwner{
        asset = _asset;
    }


    function totalAssets() public view returns(uint256){
            return asset.balanceOf(address(this));
    }


    function deposit(uint256 assets, address receiver) external returns(uint256 shares){
            require(assets>0,"assets not enough");
            shares = convertToShares(assets);
            

    }

    function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 sharesBurned){


    }


    function convertToShares(uint256 assets) public pure returns(uint256){
        
        if(assets==0) return assets;

        
    }

    function convertToAssets(uint256 shares) public pure returns(uint256){
        return shares;
    }

}