// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "lib/solmate/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "lib/solmate/src/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "lib/solmate/src/utils/SafeTransferLib.sol";

contract ShareVault is ERC20, ReentrancyGuard {
    using SafeTransferLib for ERC20;

    error ZeroAssets();
    error ZeroShares();
    error InvalidReceiver();
    error InvalidOwner();
    error FeeTooHigh();
    error TreasuryZero();

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares);
    event FeeUpdated(uint16 feeBps);
    event TreasuryUpdated(address treasury);

    ERC20 public immutable asset;
    uint8 public immutable assetDecimals;

    uint16 public feeBps; // deposit fee in basis points (max 1000 = 10% in this template)
    address public treasury;

    constructor(
        ERC20 _asset,
        string memory _shareName,
        string memory _shareSymbol,
        address _treasury,
        uint16 _feeBps
    ) ERC20(_shareName, _shareSymbol, _asset.decimals()){
        asset = _asset;
        assetDecimals = _asset.decimals();

        if(_treasury ==address(0)) revert TreasuryZero();
        treasury = _treasury;

        if(_feeBps > 1000) revert FeeTooHigh();
        feeBps = _feeBps;

    }

    function setFeeBps(uint16 newFeeBps) external {
        if(newFeeBps>1000) revert FeeTooHigh();

        feeBps = newFeeBps;
        emit FeeUpdated(newFeeBps);
    }

    function setTreasury(address newTreasury) external {
        if(newTreasury == address(0)) revert TreasuryZero();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function totalAssets() public view returns(uint256){
        return asset.balanceOf(address(this));
    }

    function convertToShares(uint256 assetsInNet) public view returns(uint256 shares){
        if(assetsInNet ==0) return 0;
        uint256 supply = totalSupply;
        uint256 ta = totalAssets();

        if(supply == 0 || ta == 0) return assetsInNet;
        return mulDivDown(assetsInNet, supply, ta);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        if (shares == 0) return 0;

        uint256 supply = totalSupply;
        uint256 ta = totalAssets();

        if (supply == 0 || ta == 0) return shares; // init 1:1
        return mulDivDown(shares, ta, supply);
    } 





    function mulDivDown(uint256 x, uint256 y, uint256 z) internal pure returns(uint256){
        return (x * y) / z;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 z) internal pure returns(uint256){
        uint a = x * y;
        return a / z + (a % z == 0 ? 0 : 1);
    }

}