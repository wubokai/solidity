// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    function price(address token) external view returns (uint256);
}

interface IShareVaultV2StrategyLike {
    function totalSupply() external view returns (uint256);
    function previewRedeem(uint256 shares) external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice price(vaultShare) in 1e18 USD.
/// Uses previewRedeem(1e18) so rounding is conservative and matches vault math.
contract VaultShareOracle is IOracle {
    uint256 internal constant WAD = 1e18;

    IShareVaultV2StrategyLike public immutable vault;
    IOracle public immutable baseOracle; // oracle for underlying asset USD price

    constructor(address vault_, address baseOracle_) {
        vault = IShareVaultV2StrategyLike(vault_);
        baseOracle = IOracle(baseOracle_);
    }

    function price(address token) external view returns (uint256) {
        require(token == address(vault), "VaultShareOracle: token!=vault");

        uint256 supply = vault.totalSupply();
        if (supply == 0) return 0;

        // Use previewRedeem(1e18) to keep oracle rounding conservative and
        // consistent with the vault's share->asset conversion math.
        uint256 oneShareAssets = vault.previewRedeem(WAD); // asset units for 1e18 shares
        uint256 assetPriceUSD = baseOracle.price(vault.asset()); // 1e18

        // USD price = assetsPerShare * assetPriceUSD / 1e18
        return mulDivDown(oneShareAssets, assetPriceUSD, WAD);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }
}
