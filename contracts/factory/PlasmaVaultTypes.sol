// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @dev Shared types for PlasmaVault deployment system
struct FeeConfig {
    uint256 iporDaoManagementFee;
    uint256 iporDaoPerformanceFee;
    uint256 atomistManagementFee;
    uint256 atomistPerformanceFee;
    address feeRecipientAddress;
    address iporDaoFeeRecipientAddress;
}

struct MarketSubstratesConfig {
    address substrate;
    uint256 weight;
}

struct BalanceFuseConfig {
    address fuse;
    uint256 marketId;
}

struct PlasmaVaultDeployData {
    string assetName;
    string assetSymbol;
    address underlyingToken;
    address priceOracleMiddleware;
    uint256 totalSupplyCap;
    address plasmaVaultBase;
    MarketSubstratesConfig[] marketSubstratesConfigs;
    address[] fuses;
    BalanceFuseConfig[] balanceFuses;
    FeeConfig feeConfig;
    uint256 redemptionDelayInSeconds;
}