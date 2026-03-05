// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @notice your ShareVaultV2Strategy-like
interface IShareVaultLike {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function approve(address spender, uint256 amount) external returns (bool);
}

/// @notice your MiniLendingMC-like surface (adjust these to your actual signatures)
interface ILendingLike {
    function depositCollateral(address token, uint256 amount, address onBehalfOf) external;
    function withdrawCollateral(address token, uint256 amount, address to) external;

    function borrow(uint256 amount, address to) external;
    function repay(uint256 amount, address onBehalfOf) external;

    // If your lending uses ERC20 transferFrom inside, router must approve lending.
}

contract VaultLendingRouter {
    IShareVaultLike public immutable vault;
    ILendingLike public immutable lending;
    address public immutable asset; // vault underlying

    constructor(IShareVaultLike _vault, ILendingLike _lending) {
        vault = _vault;
        lending = _lending;
        asset = _vault.asset();
    }

    function depositAndCollateralize(uint256 assets, address user) external returns (uint256 shares) {
        IERC20Like(asset).transferFrom(user, address(this), assets);
        IERC20Like(asset).approve(address(vault), assets);
        shares = vault.deposit(assets, address(this));
        vault.approve(address(lending), shares);
        lending.depositCollateral(address(vault), shares, user);

    }
    
    function repayAndRedeem(uint256 repayAmount, uint256 shareAmount, address user) external returns (uint256 assetsOut) {
        lending.withdrawCollateral(address(vault), shareAmount, address(this));
        assetsOut = vault.redeem(shareAmount, user, address(this));
    }
    

}