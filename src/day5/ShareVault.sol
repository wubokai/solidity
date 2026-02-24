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

    function previewDeposit(uint256 assetsGross) public view returns (uint256 sharesOut) {
        if(assetsGross == 0) return 0;
        uint256 fee = feeOnDeposit(assetsGross);
        uint256 assetsNet = assetsGross - fee;
        sharesOut = convertToShares(assetsNet);
    }

    function previewMint(uint256 shares) public view returns (uint256 assetsGrossIn){
        if(shares == 0) return 0;
        uint256 supply = totalSupply;
        uint256 ta = totalAssets();
        uint256 netAssets;
        if(supply == 0 || ta == 0){
            netAssets = shares;
        } else{
            netAssets = mulDivUp(shares, ta, supply);
        }

        uint16 bps = feeBps;
        if(bps == 0) return netAssets;

        assetsGrossIn = mulDivUp(netAssets, 10_000, 10_000 - bps);

    }


    function previewWithdraw(uint256 assets) public view returns (uint256 sharesBurn) {
        if(assets == 0) return 0;
        uint256 supply = totalSupply;
        uint256 ta = totalAssets();

        if(supply == 0 || ta == 0) return assets;
        sharesBurn = mulDivUp(assets, supply, ta);

    }

    function previewRedeem(uint256 shares) public view returns (uint256 assetsOut) {
        if(shares == 0) return 0;
        assetsOut = convertToAssets(shares);
    }


    function deposit(uint256 assetsGross, address receiver) external nonReentrant returns (uint256 sharesOut) {
        if(receiver == address(0)) revert InvalidReceiver();
        if(assetsGross == 0) revert ZeroAssets();
        uint256 fee = feeOnDeposit(assetsGross);
        uint256 netAssets = assetsGross - fee;
        sharesOut = convertToShares(netAssets);
        if(sharesOut == 0) revert ZeroShares();

        _mint(receiver, sharesOut);

        asset.safeTransferFrom(msg.sender, address(this), assetsGross);
        if(fee!=0) asset.safeTransfer(treasury, fee);

        emit Deposit(msg.sender, receiver, netAssets, sharesOut);

    }

    function mint(uint256 shares, address receiver) external nonReentrant returns (uint256 assetsGrossIn) {
        if(shares == 0) revert ZeroShares();
        if(receiver == address(0)) revert InvalidReceiver();

        assetsGrossIn = previewMint(shares);
        if(assetsGrossIn == 0) revert ZeroAssets();

        asset.safeTransferFrom(msg.sender, address(this), assetsGrossIn);
        uint256 fee = feeOnDeposit(assetsGrossIn);
        uint256 netAssets = assetsGrossIn - fee;

        if(fee!=0) asset.safeTransfer(treasury, fee);
        _mint(receiver, shares);

        uint256 impliedShares = convertToShares(netAssets);
        require(impliedShares >= shares, "UNDERPAID_MINT");
        emit Deposit(msg.sender, receiver, netAssets, shares);

    }   

    function withdraw(uint256 assets, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 sharesBurn)
    {
        if(receiver == address(0)) revert InvalidReceiver();
        if(owner == address(0)) revert InvalidOwner();
        if(assets == 0) revert ZeroAssets();
        sharesBurn = previewWithdraw(assets);
        if(sharesBurn == 0) revert ZeroShares();
        if(msg.sender != owner) _spendAllowance(owner, msg.sender, sharesBurn);
        _burn(owner, sharesBurn);
        asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, sharesBurn);
    }


    function redeem(uint256 shares, address receiver, address owner)
        external
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (receiver == address(0)) revert InvalidReceiver();
        if (owner == address(0)) revert InvalidOwner();
        if (shares == 0) revert ZeroShares();

        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        assetsOut = previewRedeem(shares);
        if (assetsOut == 0) revert ZeroAssets();
        _burn(owner, shares);
        asset.safeTransfer(receiver, assetsOut);
        emit Withdraw(msg.sender, receiver, owner, assetsOut, shares);

    }

    function _spendAllowance(address owner, address spender, uint256 amount) internal {
        uint256 allowed = allowance[owner][spender];
        if(allowed != type(uint256).max){
            require(allowed >= amount, "ALLOWANCE");
            allowance[owner][spender] = allowed - amount;
            emit Approval(owner, spender, allowance[owner][spender]);
        }
    }

    function feeOnDeposit(uint256 assetsGross) public view returns (uint256) {
        uint16 bps = feeBps;
        if(bps == 0) return 0;
        return (assetsGross * bps) / 10_000;
    }


    function mulDivDown(uint256 x, uint256 y, uint256 z) internal pure returns(uint256){
        return (x * y) / z;
    }

    function mulDivUp(uint256 x, uint256 y, uint256 z) internal pure returns(uint256){
        uint a = x * y;
        return a / z + (a % z == 0 ? 0 : 1);
    }

}