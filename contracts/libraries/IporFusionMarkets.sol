// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

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

    /// @dev Fluid rewards market
    uint256 public constant FLUID_REWARDS = 24;

    /// @dev Curve gauge ERC4626 market
    uint256 public constant CURVE_GAUGE_ERC4626 = 25;

    /// @dev Compound V3 market WETH
    uint256 public constant COMPOUND_V3_WETH = 26;

    uint256 public constant HARVEST_HARD_WORK = 27;

    /// @dev TAC staking market
    uint256 public constant TAC_STAKING = 28;

    /// @dev Liquity V2 market
    uint256 public constant LIQUITY_V2 = 29;

    uint256 public constant AERODROME = 30;

    /// @dev Velodrome Superchain market
    uint256 public constant VELODROME_SUPERCHAIN = 31;

    /// @dev Velodrome Superchain Slipstream market
    /// @dev Substrate type: VelodromeSuperchainSlipstreamSubstrate
    uint256 public constant VELODROME_SUPERCHAIN_SLIPSTREAM = 32;

    /// @dev Velodrome Superchain Slipstream market
    /// @dev Substrate type: AerodromeSlipstreamSubstrate
    uint256 public constant AREODROME_SLIPSTREAM = 33;

    /// @dev StakeDaoV2 market
    /// @dev Substrate type: address
    /// @dev Substrate values: address of the Stake DAO Reward Vault contract
    uint256 public constant STAKE_DAO_V2 = 34;

    /// @dev Silo Finance V2 market
    /// @dev Substrate type: address
    /// @dev Substrate values: address of the Silo Config contract
    uint256 public constant SILO_V2 = 35;

    /// @dev Balancer market
    /// @dev Substrate type: BalancerSubstrate (pool or gauge addresses)
    /// @dev Substrate values: Balancer pool or gauge addresses
    /// @dev Supports both Balancer pools and liquidity gauges for LP token management
    uint256 public constant BALANCER = 36;

    /// @dev Yield Basis LT market
    /// @dev Substrate type: address
    /// @dev Substrate values: Yield Basis LT tokens addresses
    uint256 public constant YIELD_BASIS_LT = 37;

    /// @dev Enso Finance market
    /// @dev Substrate type: EnsoSubstrate
    /// @dev Substrate values: Encoded combination of target address and function selector
    /// @dev Example substrate encoding:
    ///      - For token transfers: EnsoSubstrateLib.encode(Substrate({
    ///          target_: USDC,
    ///          functionSelector_: ERC20.transfer.selector
    ///        }))
    ///      - For swaps: EnsoSubstrateLib.encode(Substrate({
    ///          target_: swapTarget,
    ///          functionSelector_: ISwap.swap.selector
    ///        }))
    /// @dev Used for executing Enso Finance operations via EnsoExecutor contract
    /// @dev Supports token transfers, swaps and other operations defined in DelegateEnsoShortcuts

    uint256 public constant ENSO = 38;

    /// @dev Ebisu market
    /// @dev Substrate type: EbisuZapperSubstrate
    uint256 public constant EBISU = 39;

    /// @dev Async Action market
    /// @dev Substrate type: AsyncActionFuseSubstrate
    /// @dev Substrate values: Three types of substrates are supported:
    ///      - ALLOWED_AMOUNT_TO_OUTSIDE: Limits on asset amounts that can be transferred to AsyncExecutor
    ///        Encoded as: AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(AsyncActionFuseSubstrate({
    ///          substrateType: AsyncActionFuseSubstrateType.ALLOWED_AMOUNT_TO_OUTSIDE,
    ///          data: AsyncActionFuseLib.encodeAllowedAmountToOutside(AllowedAmountToOutside({
    ///            asset: tokenAddress,
    ///            amount: maxAmount (uint88, max 2^88 - 1)
    ///          }))
    ///        }))
    ///      - ALLOWED_TARGETS: Permitted target addresses and function selectors for execution
    ///        Encoded as: AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(AsyncActionFuseSubstrate({
    ///          substrateType: AsyncActionFuseSubstrateType.ALLOWED_TARGETS,
    ///          data: AsyncActionFuseLib.encodeAllowedTargets(AllowedTargets({
    ///            target: contractAddress,
    ///            selector: functionSelector
    ///          }))
    ///        }))
    ///      - ALLOWED_EXIT_SLIPPAGE: Maximum slippage threshold for balance validation (18-decimal fixed-point, 1e18 = 100%)
    ///        Encoded as: AsyncActionFuseLib.encodeAsyncActionFuseSubstrate(AsyncActionFuseSubstrate({
    ///          substrateType: AsyncActionFuseSubstrateType.ALLOWED_EXIT_SLIPPAGE,
    ///          data: AsyncActionFuseLib.encodeAllowedSlippage(AllowedSlippage({
    ///            slippage: slippageValue (uint248, max 2^248 - 1)
    ///          }))
    ///        }))
    /// @dev Used for executing asynchronous multi-step operations via AsyncExecutor contract
    /// @dev Validates token transfers and target/selector combinations against granted substrates before execution
    /// @dev Supports batch execution of multiple calls with ETH value forwarding
    uint256 public constant ASYNC_ACTION = 40;

    /// @dev Morpho liquidity in markets market
    uint256 public constant MORPHO_LIQUIDITY_IN_MARKETS = 41;

    /// @dev Odos Swapper market for optimized token swapping via Odos Smart Order Routing V3
    /// @dev Substrate type: OdosSubstrateType (Token or Slippage)
    /// @dev Substrate values:
    ///      - Token: Allowed token addresses for swapping (encoded with OdosSubstrateLib.encodeTokenSubstrate)
    ///      - Slippage: Custom slippage limit in WAD (encoded with OdosSubstrateLib.encodeSlippageSubstrate)
    /// @dev Used for executing Odos swaps via OdosSwapExecutor contract
    uint256 public constant ODOS_SWAPPER = 42;

    /// @dev Velora Swapper market for optimized token swapping via Velora/ParaSwap Augustus v6.2
    /// @dev Substrate type: VeloraSubstrateType (Token or Slippage)
    /// @dev Substrate values:
    ///      - Token: Allowed token addresses for swapping (encoded with VeloraSubstrateLib.encodeTokenSubstrate)
    ///      - Slippage: Custom slippage limit in WAD (encoded with VeloraSubstrateLib.encodeSlippageSubstrate)
    /// @dev Used for executing Velora swaps via VeloraSwapExecutor contract
    uint256 public constant VELORA_SWAPPER = 43;

    /// @dev Aave V4 Hub & Spoke market
    /// @dev Substrate type: AaveV4SubstrateType (Asset or Spoke)
    /// @dev Substrate values: Encoded combination of type flag and address
    ///      - Asset: AaveV4SubstrateLib.encodeAsset(tokenAddress) - ERC20 token address with flag 0x01
    ///      - Spoke: AaveV4SubstrateLib.encodeSpoke(spokeAddress) - Aave V4 Spoke contract address with flag 0x02
    uint256 public constant AAVE_V4 = 45;

    /// @dev Midas RWA market (mTBILL, mBASIS)
    /// @dev Substrate type: MidasSubstrateType (M_TOKEN, DEPOSIT_VAULT, REDEMPTION_VAULT, INSTANT_REDEMPTION_VAULT, ASSET)
    /// @dev Substrate values: Encoded combination of type flag and address (see MidasSubstrateLib)
    uint256 public constant MIDAS = 45;

    /// @dev Dolomite market
    /// @dev Substrate type: DolomiteSubstrate (asset, subAccountId, canBorrow)
    /// @dev Substrate values: Encoded combination of asset address, sub-account ID, and borrow permission
    uint256 public constant DOLOMITE = 46;

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

    /// @dev Market 6 for ERC4626 Vault
    uint256 public constant ERC4626_0006 = 100_006;

    /// @dev Market 7 for ERC4626 Vault
    uint256 public constant ERC4626_0007 = 100_007;

    /// @dev Market 8 for ERC4626 Vault
    uint256 public constant ERC4626_0008 = 100_008;

    /// @dev Market 9 for ERC4626 Vault
    uint256 public constant ERC4626_0009 = 100_009;

    /// @dev Market 10 for ERC4626 Vault
    uint256 public constant ERC4626_0010 = 100_010;

    /// @dev Market 11 for ERC4626 Vault
    uint256 public constant ERC4626_0011 = 100_011;

    /// @dev Market 12 for ERC4626 Vault
    uint256 public constant ERC4626_0012 = 100_012;

    /// @dev Market 13 for ERC4626 Vault
    uint256 public constant ERC4626_0013 = 100_013;

    /// @dev Market 14 for ERC4626 Vault
    uint256 public constant ERC4626_0014 = 100_014;

    /// @dev Market 15 for ERC4626 Vault
    uint256 public constant ERC4626_0015 = 100_015;

    /// @dev Market 16 for ERC4626 Vault
    uint256 public constant ERC4626_0016 = 100_016;

    /// @dev Market 17 for ERC4626 Vault
    uint256 public constant ERC4626_0017 = 100_017;

    /// @dev Market 18 for ERC4626 Vault
    uint256 public constant ERC4626_0018 = 100_018;

    /// @dev Market 19 for ERC4626 Vault
    uint256 public constant ERC4626_0019 = 100_019;

    /// @dev Market 20 for ERC4626 Vault
    uint256 public constant ERC4626_0020 = 100_020;

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

    /// @dev Exchange Rate Limiter market for pre-hook execution
    /// @dev Substrate type: bytes32 packed ExchangeRateLimiterConfig (see ExchangeRateLimiterConfigLib)
    /// @dev Substrate values:
    /// @dev  - PREHOOKS/POSTHOOKS: Hook { hookAddress, index } packed into bytes31 and wrapped into bytes32 with HookType
    /// @dev  - VALIDATOR: ValidatorData { exchangeRate, threshold } packed into bytes31 and wrapped into bytes32 with HookType
    /// @dev Threshold is expressed in 1e18 precision, where 1e18 = 100%
    /// @dev Used by ExchangeRateLimiterPreHook to orchestrate pre/post hooks and validate exchange rate drift
    uint256 public constant EXCHANGE_RATE_VALIDATOR = type(uint256).max - 2;

    /// @dev Special market ID used to validate balances of substrates (assets) defined in this market.
    /// @dev This market ID is used only for balance validation purposes and does not represent an actual market.
    uint256 public constant ASSETS_BALANCE_VALIDATION = type(uint256).max - 1;

    /// @dev Market used in cases where the fuse does not require maintaining any balance and there are no dependent balances.
    uint256 public constant ZERO_BALANCE_MARKET = type(uint256).max;
}
