// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Predefined markets used in the IPOR Fusion protocol
/// @notice For documentation purposes: When new markets are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library IporFusionMarkets {
    /// @dev AAVE V3 market
    uint256 public constant AAVE_V3 = 1;

    /// @dev Compound V3 market USDC
    uint256 public constant COMPOUND_V3_USDC = 2;

    /// @dev Gearbox V3 market
    uint256 public constant GEARBOX_POOL_V3 = 3;
    /// @dev if this marketId is added to the PlasmaVault, one need add dependence graph with balance of GEARBOX_POOL_V3
    uint256 public constant GEARBOX_FARM_DTOKEN_V3 = 4;

    /// @dev Fluid Instadapp market
    uint256 public constant FLUID_INSTADAPP_POOL = 5;
    uint256 public constant FLUID_INSTADAPP_STAKING = 6;

    uint256 public constant ERC20_VAULT_BALANCE = 7;

    /// @dev if this marketId is added to the PlasmaVault, one need add dependence graph with balance of ERC20_VAULT_BALANCE
    uint256 public constant UNISWAP_SWAP_V3_POSITIONS = 8;

    /// @dev Uniswap market
    /// @dev if this marketId is added to the PlasmaVault, one need add dependence graph with balance of ERC20_VAULT_BALANCE
    uint256 public constant UNISWAP_SWAP_V2 = 9;
    /// @dev if this marketId is added to the PlasmaVault, one need add dependence graph with balance of ERC20_VAULT_BALANCE
    uint256 public constant UNISWAP_SWAP_V3 = 10;

    /// @dev Euler market
    uint256 public constant EULER_V2 = 11;

    /// @dev universal token swapper, one need add dependence graph with balance of ERC20_VAULT_BALANCE
    uint256 public constant UNIVERSAL_TOKEN_SWAPPER = 12;

    /// @dev Compound V3 market USDT
    uint256 public constant COMPOUND_V3_USDT = 13;

    /// @dev Morpho market
    uint256 public constant MORPHO = 14;

    /// @dev Spark market
    uint256 public constant SPARK = 15;

    /// @dev Curve market
    uint256 public constant CURVE_POOL = 16;
    uint256 public constant CURVE_LP_GAUGE = 17;

    uint256 public constant RAMSES_V2_POSITIONS = 18;

    /// @dev Morpho flash loan market, one need add dependence graph with balance of ERC20_VAULT_BALANCE
    uint256 public constant MORPHO_FLASH_LOAN = 19;

    /// @dev AAVE V3 lido market
    uint256 public constant AAVE_V3_LIDO = 20;

    /// @dev Moonwell market
    uint256 public constant MOONWELL = 21;

    /// @dev Morpho rewards market
    uint256 public constant MORPHO_REWARDS = 22;

    /// @dev Pendle market
    uint256 public constant PENDLE = 23;

    /// @dev Curve gauge ERC4626 market
    uint256 public constant CURVE_GAUGE_ERC4626 = 24;

    /// @dev Market 1 for ERC4626 Vault
    uint256 public constant ERC4626_0001 = 100_001;

    /// @dev Market 2 for ERC4626 Vault
    uint256 public constant ERC4626_0002 = 100_002;

    /// @dev Market 3 for ERC4626 Vault
    uint256 public constant ERC4626_0003 = 100_003;

    /// @dev Market 4 for ERC4626 Vault
    uint256 public constant ERC4626_0004 = 100_004;

    /// @dev Market 5 for ERC4626 Vault
    uint256 public constant ERC4626_0005 = 100_005;

    /// @dev Meta Morpho Market 1
    uint256 public constant META_MORPHO_0001 = 200_001;

    /// @dev Meta Morpho Market 2
    uint256 public constant META_MORPHO_0002 = 200_002;

    /// @dev Meta Morpho Market 3
    uint256 public constant META_MORPHO_0003 = 200_003;

    /// @dev Meta Morpho Market 4
    uint256 public constant META_MORPHO_0004 = 200_004;

    /// @dev Meta Morpho Market 5
    uint256 public constant META_MORPHO_0005 = 200_005;

    /// @dev Meta Morpho Market 6
    uint256 public constant META_MORPHO_0006 = 200_006;

    /// @dev Meta Morpho Market 7
    uint256 public constant META_MORPHO_0007 = 200_007;

    /// @dev Meta Morpho Market 8
    uint256 public constant META_MORPHO_0008 = 200_008;

    /// @dev Meta Morpho Market 9
    uint256 public constant META_MORPHO_0009 = 200_009;

    /// @dev Meta Morpho Market 10
    uint256 public constant META_MORPHO_0010 = 200_010;
}
