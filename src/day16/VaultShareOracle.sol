// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IOracle {
    function price(address token) external view returns (uint256);
}

interface IShareVaultV2StrategyLike {
    function totalAssets() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function asset() external view returns (address);
}

/// @notice price(vaultShare) in 1e18 USD, using:
/// sharePrice = totalAssets/totalSupply (asset per share)
/// priceShareUSD = sharePrice * price(assetUSD)
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

        uint256 ta = vault.totalAssets(); // asset units (assume asset decimals = 18 in your tests)
        uint256 assetPriceUSD = baseOracle.price(vault.asset()); // 1e18

        // sharePriceAsset = ta / supply (asset per share) in WAD terms (both 18-decimals in your system)
        uint256 sharePriceAsset = mulDivDown(ta, WAD, supply); // 1e18

        // USD price = sharePriceAsset * assetPriceUSD / 1e18
        return mulDivDown(sharePriceAsset, assetPriceUSD, WAD);
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256) {
        return (x * y) / d;
    }
}