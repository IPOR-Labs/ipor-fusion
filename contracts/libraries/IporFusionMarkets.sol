// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Predefined markets used in the IPOR Fusion protocol
/// @notice For documentation purposes: When new markets are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library IporFusionMarkets {
    /// @dev AAVE V3 market
    uint256 public constant AAVE_V3 = 1;

    /// @dev Compound V3 market
    uint256 public constant COMPOUND_V3 = 2;

    /// @dev Gearbox V3 market
    uint256 public constant GEARBOX_POOL_V3 = 3;
    uint256 public constant GEARBOX_FARM_DTOKEN_V3 = 4;

    /// @dev Fluid Instadapp market
    uint256 public constant FLUID_INSTADAPP_POOL = 5;
    uint256 public constant FLUID_INSTADAPP_STAKING = 6;

    uint256 public constant ERC20_VAULT_BALANCE = 8;

    /// @dev Curve USDM/USDC/LP market
    uint256 public constant CURVE_POOL = 9;
    uint256 public constant CURVE_LP_GAUGE = 10;
}