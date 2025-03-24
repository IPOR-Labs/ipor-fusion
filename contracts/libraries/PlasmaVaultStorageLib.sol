// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title Plasma Vault Storage Library
 * @notice Library managing storage layout and access for the PlasmaVault system using ERC-7201 namespaced storage pattern
 * @dev This library is a core component of the PlasmaVault system that:
 * 1. Defines and manages all storage structures using ERC-7201 namespaced storage pattern
 * 2. Provides storage access functions for PlasmaVault.sol, PlasmaVaultBase.sol and PlasmaVaultGovernance.sol
 * 3. Ensures storage safety for the upgradeable vault system
 *
 * Storage Components:
 * - Core ERC4626 vault storage (asset, decimals)
 * - Market management (assets, balances, substrates)
 * - Fee system storage (performance, management fees)
 * - Access control and execution state
 * - Fuse system configuration
 * - Price oracle and rewards management
 *
 * Key Integrations:
 * - Used by PlasmaVault.sol for core vault operations and asset management
 * - Used by PlasmaVaultGovernance.sol for configuration and admin functions
 * - Used by PlasmaVaultBase.sol for ERC20 functionality and access control
 *
 * Security Considerations:
 * - Uses ERC-7201 namespaced storage pattern to prevent storage collisions
 * - Each storage struct has a unique namespace derived from its purpose
 * - Critical for maintaining storage integrity in upgradeable contracts
 * - Storage slots are carefully chosen and must not be modified
 *
 * @custom:security-contact security@ipor.io
 */
library PlasmaVaultStorageLib {
    /**
     * @dev Storage slot for ERC4626 vault configuration following ERC-7201 namespaced storage pattern
     * @notice This storage location is used to store the core ERC4626 vault data (asset address and decimals)
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC4626")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Important:
     * - This value MUST NOT be changed as it's used by OpenZeppelin's ERC4626 implementation
     * - Changing this value would break storage compatibility with existing deployments
     * - Used by PlasmaVault.sol for core vault operations like deposit/withdraw
     *
     * Storage Layout:
     * - Points to ERC4626Storage struct containing:
     *   - asset: address of the underlying token
     *   - underlyingDecimals: decimals of the underlying token
     */
    bytes32 private constant ERC4626_STORAGE_LOCATION =
        0x0773e532dfede91f04b12a73d3d2acd361424f41f76b4fb79f090161e36b4e00;

    /**
     * @dev Storage slot for ERC20Capped configuration following ERC-7201 namespaced storage pattern
     * @notice This storage location manages the total supply cap functionality for the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.ERC20Capped")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Important:
     * - This value MUST NOT be changed as it's used by OpenZeppelin's ERC20Capped implementation
     * - Changing this value would break storage compatibility with existing deployments
     * - Used by PlasmaVault.sol and PlasmaVaultBase.sol for supply cap enforcement
     *
     * Storage Layout:
     * - Points to ERC20CappedStorage struct containing:
     *   - cap: maximum total supply allowed for the vault tokens
     *
     * Usage:
     * - Enforces maximum supply limits during minting operations
     * - Can be temporarily disabled for fee-related minting operations
     * - Critical for maintaining vault supply control
     */
    bytes32 private constant ERC20_CAPPED_STORAGE_LOCATION =
        0x0f070392f17d5f958cc1ac31867dabecfc5c9758b4a419a200803226d7155d00;

    /**
     * @dev Storage slot for managing the ERC20 supply cap validation state
     * @notice Controls whether total supply cap validation is active or temporarily disabled
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.Erc20CappedValidationFlag")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Provides a mechanism to temporarily disable supply cap checks
     * - Essential for special minting operations like fee distribution
     * - Used by PlasmaVault.sol during performance and management fee minting
     *
     * Storage Layout:
     * - Points to ERC20CappedValidationFlag struct containing:
     *   - value: flag indicating if cap validation is enabled (0) or disabled (1)
     *
     * Usage Pattern:
     * - Default state: Enabled (0) - enforces supply cap
     * - Temporarily disabled (1) during:
     *   - Performance fee minting
     *   - Management fee minting
     * - Always re-enabled after special minting operations
     *
     * Security Note:
     * - Critical for maintaining controlled token supply
     * - Only disabled briefly during authorized fee operations
     * - Must be properly re-enabled to prevent unlimited minting
     */
    bytes32 private constant ERC20_CAPPED_VALIDATION_FLAG =
        0xaef487a7a52e82ae7bbc470b42be72a1d3c066fb83773bf99cce7e6a7df2f900;

    /**
     * @dev Storage slot for tracking total assets across all markets in the Plasma Vault
     * @notice Maintains the global accounting of all assets managed by the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultTotalAssetsInAllMarkets")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks the total value of assets managed by the vault across all markets
     * - Used for global vault accounting and share price calculations
     * - Critical for ERC4626 compliance and vault operations
     *
     * Storage Layout:
     * - Points to TotalAssets struct containing:
     *   - value: total assets in underlying token decimals
     *
     * Usage:
     * - Updated during deposit/withdraw operations
     * - Used in share price calculations
     * - Referenced for fee calculations
     * - Key component in asset distribution checks
     *
     * Integration Points:
     * - PlasmaVault.sol: Used in totalAssets() calculations
     * - Fee System: Used as base for fee calculations
     * - Asset Protection: Used in distribution limit checks
     *
     * Security Considerations:
     * - Must be accurately maintained for proper vault operation
     * - Critical for share price accuracy
     * - Any updates must consider all asset sources (markets, rewards, etc.)
     */
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS =
        0x24e02552e88772b8e8fd15f3e6699ba530635ffc6b52322da922b0b497a77300;

    /**
     * @dev Storage slot for tracking assets per individual market in the Plasma Vault
     * @notice Maintains per-market asset accounting for the vault's distributed positions
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultTotalAssetsInMarket")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks assets allocated to each market individually
     * - Enables market-specific asset distribution control
     * - Used for market balance validation and limits enforcement
     *
     * Storage Layout:
     * - Points to MarketTotalAssets struct containing:
     *   - value: mapping(uint256 marketId => uint256 assets)
     *   - Assets stored in underlying token decimals
     *
     * Usage:
     * - Updated during market operations via fuses
     * - Used in market balance checks
     * - Referenced for market limit validations
     * - Key for asset distribution protection
     *
     * Integration Points:
     * - Balance Fuses: Update market balances
     * - Asset Distribution Protection: Enforce market limits
     * - Withdrawal Logic: Check available assets per market
     *
     * Security Considerations:
     * - Critical for market-specific asset limits
     * - Must be synchronized with actual market positions
     * - Updates protected by balance fuse system
     */
    bytes32 private constant PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET =
        0x656f5ca8c676f20b936e991a840e1130bdd664385322f33b6642ec86729ee600;

    /**
     * @dev Storage slot for market substrates configuration in the Plasma Vault
     * @notice Manages the configuration of supported assets and sub-markets for each market
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultMarketSubstrates")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Defines which assets/sub-markets are supported in each market
     * - Controls market-specific asset allowances
     * - Essential for market integration configuration
     *
     * Storage Layout:
     * - Points to MarketSubstrates struct containing:
     *   - value: mapping(uint256 marketId => MarketSubstratesStruct)
     *     where MarketSubstratesStruct contains:
     *     - substrateAllowances: mapping(bytes32 => uint256) for permission control
     *     - substrates: bytes32[] list of supported substrates
     *
     * Usage:
     * - Configured by governance for each market
     * - Referenced during market operations
     * - Used by fuses to validate operations
     * - Controls which assets can be used in each market
     *
     * Integration Points:
     * - Fuse System: Validates allowed substrates
     * - Market Operations: Controls available assets
     * - Governance: Manages market configurations
     *
     * Security Considerations:
     * - Critical for controlling market access
     * - Only modifiable through governance
     * - Impacts market operation permissions
     */
    bytes32 private constant CFG_PLASMA_VAULT_MARKET_SUBSTRATES =
        0x78e40624004925a4ef6749756748b1deddc674477302d5b7fe18e5335cde3900;

    /**
     * @dev Storage slot for pre-hooks configuration in the Plasma Vault
     * @notice Manages function-specific pre-execution hooks and their implementations
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultPreHooks")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Maps function selectors to their pre-execution hook implementations
     * - Enables customizable pre-execution validation and logic
     * - Provides extensible function-specific behavior
     * - Coordinates cross-function state updates
     *
     * Storage Layout:
     * - Points to PreHooksConfig struct containing:
     *   - hooksImplementation: mapping(bytes4 selector => address implementation)
     *   - selectors: bytes4[] array of registered function selectors
     *   - indexes: mapping(bytes4 selector => uint256 index) for O(1) selector lookup
     *
     * Usage Pattern:
     * - Each function can have one designated pre-hook
     * - Hooks execute before main function logic
     * - Selector array enables efficient iteration over registered hooks
     * - Index mapping provides quick hook existence checks
     *
     * Integration Points:
     * - PlasmaVault.execute: Pre-execution hook invocation
     * - PreHooksHandler: Hook execution coordination
     * - PlasmaVaultGovernance: Hook configuration
     * - Function-specific hooks: Custom validation logic
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Critical for function execution control
     * - Must validate hook implementations
     * - Requires careful state management
     * - Key component of vault security layer
     */
    bytes32 private constant CFG_PLASMA_VAULT_PRE_HOOKS =
        0xd334d8b26e68f82b7df26f2f64b6ffd2aaae5e2fc0e8c144c4b3598dcddd4b00;

    /**
     * @dev Storage slot for balance fuses configuration in the Plasma Vault
     * @notice Maps markets to their balance fuses and maintains an ordered list of active markets
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultBalanceFuses")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Associates balance fuses with specific markets for asset tracking
     * - Maintains ordered list of active markets for efficient iteration
     * - Enables market balance validation and updates
     * - Coordinates multi-market balance operations
     *
     * Storage Layout:
     * - Points to BalanceFuses struct containing:
     *   - fuseAddresses: mapping(uint256 marketId => address fuseAddress)
     *   - marketIds: uint256[] array of active market IDs
     *   - indexes: Maps market IDs to their position+1 in marketIds array
     *
     * Usage Pattern:
     * - Each market has one designated balance fuse
     * - Market IDs array enables efficient iteration over active markets
     * - Index mapping provides quick market existence checks
     * - Used during balance updates and market operations
     *
     * Integration Points:
     * - PlasmaVault._updateMarketsBalances: Market balance tracking
     * - Balance Fuses: Market position management
     * - PlasmaVaultGovernance: Fuse configuration
     * - Asset Protection: Balance validation
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Critical for accurate asset tracking
     * - Must maintain market list integrity
     * - Requires proper fuse address validation
     * - Key component of vault accounting
     */
    bytes32 private constant CFG_PLASMA_VAULT_BALANCE_FUSES =
        0x150144dd6af711bac4392499881ec6649090601bd196a5ece5174c1400b1f700;

    /**
     * @dev Storage slot for instant withdrawal fuses configuration
     * @notice Stores ordered array of fuses that can be used for instant withdrawals
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesArray")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Maintains list of fuses available for instant withdrawals
     * - Defines order of withdrawal attempts
     * - Enables efficient withdrawal path selection
     *
     * Storage Layout:
     * - Points to InstantWithdrawalFuses struct containing:
     *   - value: address[] array of fuse addresses
     *   - Order of fuses in array determines withdrawal priority
     *
     * Usage:
     * - Referenced during withdrawal operations
     * - Used by PlasmaVault.sol in _withdrawFromMarkets
     * - Determines withdrawal execution sequence
     *
     * Integration Points:
     * - Withdrawal System: Defines available withdrawal paths
     * - Fuse System: Lists supported instant withdrawal fuses
     * - Governance: Manages withdrawal configuration
     *
     * Security Considerations:
     * - Order of fuses is critical for optimal withdrawals
     * - Same fuse can appear multiple times with different params
     * - Must be carefully managed to ensure withdrawal efficiency
     */
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY =
        0xd243afa3da07e6bdec20fdd573a17f99411aa8a62ae64ca2c426d3a86ae0ac00;

    /**
     * @dev Storage slot for price oracle middleware configuration
     * @notice Stores the address of the price oracle middleware used for asset price conversions
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.PriceOracleMiddleware")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Provides price feed access for asset valuations
     * - Essential for market value calculations
     * - Used in balance conversions and limit checks
     *
     * Storage Layout:
     * - Points to PriceOracleMiddleware struct containing:
     *   - value: address of the price oracle middleware contract
     *
     * Usage:
     * - Used during market balance updates
     * - Required for USD value calculations
     * - Critical for asset distribution checks
     *
     * Integration Points:
     * - Balance Fuses: Asset value calculations
     * - Market Operations: Price conversions
     * - Asset Protection: Value-based limits
     *
     * Security Considerations:
     * - Must point to a valid and secure price oracle
     * - Critical for accurate vault valuations
     * - Only updatable through governance
     */
    bytes32 private constant PRICE_ORACLE_MIDDLEWARE =
        0x0d761ae54d86fc3be4f1f2b44ade677efb1c84a85fc6bb1d087dc42f1e319a00;

    /**
     * @dev Storage slot for instant withdrawal fuse parameters configuration
     * @notice Maps fuses to their specific withdrawal parameters for instant withdrawal execution
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultInstantWithdrawalFusesParams")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Stores configuration parameters for each instant withdrawal fuse
     * - Enables customized withdrawal behavior per fuse
     * - Supports multiple parameter sets for the same fuse at different indices
     *
     * Storage Layout:
     * - Points to InstantWithdrawalFusesParams struct containing:
     *   - value: mapping(bytes32 => bytes32[]) where:
     *     - key: keccak256(abi.encodePacked(fuse address, index))
     *     - value: array of parameters specific to the fuse
     *
     * Parameter Structure:
     * - params[0]: Always represents withdrawal amount in underlying token
     * - params[1+]: Fuse-specific parameters (e.g., slippage, path, market-specific data)
     *
     * Usage Pattern:
     * - Referenced during instant withdrawal operations in PlasmaVault
     * - Parameters are passed to fuse's instantWithdraw function
     * - Supports multiple parameter sets for same fuse with different indices
     *
     * Integration Points:
     * - PlasmaVault._withdrawFromMarkets: Uses params for withdrawal execution
     * - PlasmaVaultGovernance: Manages parameter configuration
     * - Fuse Contracts: Receive and interpret parameters during withdrawal
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Critical for controlling withdrawal behavior
     * - Parameters must be carefully validated per fuse requirements
     * - Order of parameters must match fuse expectations
     */
    bytes32 private constant CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS =
        0x45a704819a9dcb1bb5b8cff129eda642cf0e926a9ef104e27aa53f1d1fa47b00;

    /**
     * @dev Storage slot for fee configuration in the Plasma Vault
     * @notice Manages the fee configuration including performance and management fees
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.CfgPlasmaVaultFeeConfig")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Stores comprehensive fee configuration for the vault
     * - Manages both IPOR DAO and recipient-specific fee settings
     * - Enables flexible fee distribution model
     *
     * Storage Layout:
     * - Points to FeeConfig struct containing:
     *   - feeFactory: address of the FeeManagerFactory contract
     *   - iporDaoManagementFee: management fee percentage for IPOR DAO
     *   - iporDaoPerformanceFee: performance fee percentage for IPOR DAO
     *   - iporDaoFeeRecipientAddress: address receiving IPOR DAO fees
     *   - recipientManagementFees: array of management fee percentages for other recipients
     *   - recipientPerformanceFees: array of performance fee percentages for other recipients
     *
     * Fee Structure:
     * - Management fees: Continuous time-based fees on AUM
     * - Performance fees: Charged on positive vault performance
     * - All fees in basis points (1/10000)
     *
     * Integration Points:
     * - FeeManagerFactory: Deploys fee management contracts
     * - FeeManager: Handles fee calculations and distributions
     * - PlasmaVault: References for fee realizations
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Fee percentages must be within reasonable bounds
     * - Critical for vault economics and sustainability
     * - Must maintain proper recipient configurations
     */
    bytes32 private constant CFG_PLASMA_VAULT_FEE_CONFIG =
        0x78b5ce597bdb64d5aa30a201c7580beefe408ff13963b5d5f3dce2dc09e89c00;

    /**
     * @dev Storage slot for performance fee data in the Plasma Vault
     * @notice Stores current performance fee configuration and recipient information
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.PlasmaVaultPerformanceFeeData")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Manages performance fee settings and collection
     * - Tracks fee recipient address
     * - Controls performance-based revenue sharing
     *
     * Storage Layout:
     * - Points to PerformanceFeeData struct containing:
     *   - feeAccount: address receiving performance fees
     *   - feeInPercentage: current fee rate (basis points, 1/10000)
     *
     * Fee Mechanics:
     * - Calculated on positive vault performance
     * - Applied during execute() operations
     * - Minted as new vault shares to fee recipient
     * - Charged only on realized gains
     *
     * Integration Points:
     * - PlasmaVault._addPerformanceFee: Fee calculation and minting
     * - FeeManager: Fee configuration management
     * - PlasmaVaultGovernance: Fee settings updates
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Fee percentage must be within defined limits
     * - Critical for fair value distribution
     * - Must maintain valid fee recipient address
     * - Requires careful handling during share minting
     */
    bytes32 private constant PLASMA_VAULT_PERFORMANCE_FEE_DATA =
        0x9399757a27831a6cfb6cf4cd5c97a908a2f8f41e95a5952fbf83a04e05288400;

    /**
     * @notice Stores management fee configuration and time tracking data
     * @dev Manages continuous fee collection with time-based accrual
     * @custom:storage-location erc7201:io.ipor.PlasmaVaultManagementFeeData
     */
    bytes32 private constant PLASMA_VAULT_MANAGEMENT_FEE_DATA =
        0x239dd7e43331d2af55e2a25a6908f3bcec2957025f1459db97dcdc37c0003f00;

    /**
     * @dev Storage slot for rewards claim manager address
     * @notice Stores the address of the contract managing external protocol rewards
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.RewardsClaimManagerAddress")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Manages external protocol reward claims
     * - Tracks claimable rewards across integrated protocols
     * - Centralizes reward collection logic
     *
     * Storage Layout:
     * - Points to RewardsClaimManagerAddress struct containing:
     *   - value: address of the rewards claim manager contract
     *
     * Functionality:
     * - Coordinates reward claims from multiple protocols
     * - Tracks unclaimed rewards in underlying asset terms
     * - Included in total assets calculations when active
     * - Optional component (can be set to address(0))
     *
     * Integration Points:
     * - PlasmaVault._getGrossTotalAssets: Includes rewards in total assets
     * - PlasmaVault.claimRewards: Executes reward collection
     * - External protocols: Source of claimable rewards
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Must handle protocol-specific claim logic safely
     * - Critical for accurate reward accounting
     * - Requires careful integration testing
     * - Should handle failed claims gracefully
     */
    bytes32 private constant REWARDS_CLAIM_MANAGER_ADDRESS =
        0x08c469289c3f85d9b575f3ae9be6831541ff770a06ea135aa343a4de7c962d00;

    /**
     * @dev Storage slot for market allocation limits
     * @notice Controls maximum asset allocation per market in the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.MarketLimits")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Enforces market-specific allocation limits
     * - Prevents over-concentration in single markets
     * - Enables risk management through diversification
     *
     * Storage Layout:
     * - Points to MarketLimits struct containing:
     *   - limitInPercentage: mapping(uint256 marketId => uint256 limit)
     *   - Limits stored in basis points (1e18 = 100%)
     *
     * Limit Mechanics:
     * - Each market has independent allocation limit
     * - Limits are percentage of total vault assets
     * - Zero limit for marketId 0 deactivates all limits
     * - Non-zero limit for marketId 0 activates limit system
     *
     * Integration Points:
     * - AssetDistributionProtectionLib: Enforces limits
     * - PlasmaVault._updateMarketsBalances: Checks limits
     * - PlasmaVaultGovernance: Limit configuration
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Critical for risk management
     * - Must handle percentage calculations carefully
     * - Requires proper market balance tracking
     * - Should prevent concentration risk
     */
    bytes32 private constant MARKET_LIMITS = 0xc2733c187287f795e2e6e84d35552a190e774125367241c3e99e955f4babf000;

    /**
     * @dev Storage slot for market balance dependency relationships
     * @notice Manages interconnected market balance update requirements
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.DependencyBalanceGraph")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Tracks dependencies between market balances
     * - Ensures atomic balance updates across related markets
     * - Maintains consistency in cross-market positions
     *
     * Storage Layout:
     * - Points to DependencyBalanceGraph struct containing:
     *   - dependencyGraph: mapping(uint256 marketId => uint256[] marketIds)
     *   - Each market maps to array of dependent market IDs
     *
     * Dependency Mechanics:
     * - Markets can depend on multiple other markets
     * - When updating a market balance, all dependent markets must be updated
     * - Dependencies are unidirectional (A->B doesn't imply B->A)
     * - Empty dependency array means no dependencies
     *
     * Integration Points:
     * - PlasmaVault._checkBalanceFusesDependencies: Resolves update order
     * - PlasmaVault._updateMarketsBalances: Ensures complete updates
     * - PlasmaVaultGovernance: Dependency configuration
     *
     * Security Considerations:
     * - Only modifiable through governance
     * - Must prevent circular dependencies
     * - Critical for market balance integrity
     * - Requires careful dependency chain validation
     * - Should handle deep dependency trees efficiently
     */
    bytes32 private constant DEPENDENCY_BALANCE_GRAPH =
        0x82411e549329f2815579116a6c5e60bff72686c93ab5dba4d06242cfaf968900;

    /**
     * @dev Storage slot for tracking execution state of vault operations
     * @notice Controls execution flow and prevents concurrent operations in the vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.executeRunning")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Prevents concurrent execution of vault operations
     * - Enables callback handling during execution
     * - Acts as a reentrancy guard for execute() operations
     *
     * Storage Layout:
     * - Points to ExecuteState struct containing:
     *   - value: uint256 flag indicating execution state
     *     - 0: No execution in progress
     *   - 1: Execution in progress
     *
     * Usage Pattern:
     * - Set to 1 at start of execute() operation
     * - Checked during callback handling
     * - Reset to 0 when execution completes
     * - Used by PlasmaVault.execute() and callback system
     *
     * Integration Points:
     * - PlasmaVault.execute: Sets/resets execution state
     * - CallbackHandlerLib: Validates callbacks during execution
     * - Fallback function: Routes callbacks during execution
     *
     * Security Considerations:
     * - Critical for preventing concurrent operations
     * - Must be properly reset after execution
     * - Protects against malicious callbacks
     * - Part of vault's security architecture
     */
    bytes32 private constant EXECUTE_RUNNING = 0x054644eb87255c1c6a2d10801735f52fa3b9d6e4477dbed74914d03844ab6600;

    /**
     * @dev Storage slot for callback handler mapping in the Plasma Vault
     * @notice Maps protocol-specific callbacks to their handler contracts
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.callbackHandler")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Routes protocol-specific callbacks to appropriate handlers
     * - Enables dynamic callback handling during vault operations
     * - Supports integration with external protocols
     * - Manages protocol-specific callback logic
     *
     * Storage Layout:
     * - Points to CallbackHandler struct containing:
     *   - callbackHandler: mapping(bytes32 => address)
     *     - key: keccak256(abi.encodePacked(sender, sig))
     *     - value: address of the handler contract
     *
     * Usage Pattern:
     * - Callbacks received during execute() operations
     * - Key generated from sender address and function signature
     * - Handler contract processes protocol-specific logic
     * - Only accessible when execution is in progress
     *
     * Integration Points:
     * - PlasmaVault.fallback: Routes incoming callbacks
     * - CallbackHandlerLib: Processes callback routing
     * - Protocol-specific handlers: Implement callback logic
     * - PlasmaVaultGovernance: Manages handler configuration
     *
     * Security Considerations:
     * - Only callable during active execution
     * - Handler addresses must be trusted
     * - Prevents unauthorized callback processing
     * - Critical for secure protocol integration
     * - Must validate callback sources
     */
    bytes32 private constant CALLBACK_HANDLER = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e00;

    /**
     * @dev Storage slot for withdraw manager contract address
     * @notice Manages withdrawal controls and permissions in the Plasma Vault
     *
     * Calculation:
     * keccak256(abi.encode(uint256(keccak256("io.ipor.WithdrawManager")) - 1)) & ~bytes32(uint256(0xff))
     *
     * Purpose:
     * - Controls withdrawal permissions and limits
     * - Manages withdrawal schedules and timing
     * - Enforces withdrawal restrictions
     * - Coordinates withdrawal validation
     *
     * Storage Layout:
     * - Points to WithdrawManager struct containing:
     *   - manager: address of the withdraw manager contract
     *   - Zero address indicates disabled withdrawal controls
     *
     * Usage Pattern:
     * - Checked during withdraw() and redeem() operations
     * - Validates withdrawal permissions
     * - Enforces withdrawal schedules
     * - Can be disabled by setting to address(0)
     *
     * Integration Points:
     * - PlasmaVault.withdraw: Checks withdrawal permissions
     * - PlasmaVault.redeem: Validates redemption requests
     * - PlasmaVaultGovernance: Manager configuration
     * - AccessManager: Permission coordination
     *
     * Security Considerations:
     * - Critical for controlling asset outflows
     * - Only modifiable through governance
     * - Must maintain withdrawal restrictions
     * - Coordinates with access control system
     * - Key component of vault security
     */
    bytes32 private constant WITHDRAW_MANAGER = 0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    /**
     * @notice Maps callback signatures to their handler contracts
     * @dev Stores routing information for protocol-specific callbacks
     * @custom:storage-location erc7201:io.ipor.callbackHandler
     */
    struct CallbackHandler {
        /// @dev key: keccak256(abi.encodePacked(sender, sig)), value: handler address
        mapping(bytes32 key => address handler) callbackHandler;
    }

    /**
     * @notice Stores and manages per-market allocation limits for the vault
     * @custom:storage-location erc7201:io.ipor.MarketLimits
     */
    struct MarketLimits {
        mapping(uint256 marketId => uint256 limit) limitInPercentage;
    }

    /**
     * @notice Core storage for ERC4626 vault implementation
     * @dev Value taken from OpenZeppelin's ERC4626 implementation - DO NOT MODIFY
     * @custom:storage-location erc7201:openzeppelin.storage.ERC4626
     */
    struct ERC4626Storage {
        /// @dev underlying asset in Plasma Vault
        address asset;
        /// @dev underlying asset decimals in Plasma Vault
        uint8 underlyingDecimals;
    }

    /// @dev Value taken from ERC20VotesUpgradeable contract, don't change it!
    /// @custom:storage-location erc7201:openzeppelin.storage.ERC20Capped
    struct ERC20CappedStorage {
        uint256 cap;
    }

    /// @notice ERC20CappedValidationFlag is used to enable or disable the total supply cap validation during execution
    /// Required for situation when performance fee or management fee is minted for fee managers
    /// @custom:storage-location erc7201:io.ipor.Erc20CappedValidationFlag
    struct ERC20CappedValidationFlag {
        uint256 value;
    }

    /**
     * @notice Stores address of the contract managing protocol reward claims
     * @dev Optional component - can be set to address(0) to disable rewards
     * @custom:storage-location erc7201:io.ipor.RewardsClaimManagerAddress
     */
    struct RewardsClaimManagerAddress {
        /// @dev total assets in the Plasma Vault
        address value;
    }

    /**
     * @notice Tracks total assets across all markets in the vault
     * @dev Used for global accounting and share price calculations
     * @custom:storage-location erc7201:io.ipor.PlasmaVaultTotalAssetsInAllMarkets
     */
    struct TotalAssets {
        /// @dev total assets in the Plasma Vault
        uint256 value;
    }

    /**
     * @notice Tracks per-market asset balances in the vault
     * @dev Used for market-specific accounting and limit enforcement
     * @custom:storage-location erc7201:io.ipor.PlasmaVaultTotalAssetsInMarket
     */
    struct MarketTotalAssets {
        /// @dev marketId => total assets in the vault in the market
        mapping(uint256 => uint256) value;
    }

    /**
     * @notice Market Substrates configuration
     * @dev Substrate - abstract item in the market, could be asset or sub market in the external protocol, it could be any item required to calculate balance in the market
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultMarketSubstrates
     */
    struct MarketSubstratesStruct {
        /// @notice Define which substrates are allowed and supported in the market
        /// @dev key can be specific asset or sub market in a specific external protocol (market), value - 1 - granted, otherwise - not granted
        mapping(bytes32 => uint256) substrateAllowances;
        /// @dev it could be list of assets or sub markets in a specific protocol or any other ids required to calculate balance in the market (external protocol)
        bytes32[] substrates;
    }

    /**
     * @notice Maps markets to their supported substrate configurations
     * @dev Stores per-market substrate allowances and lists
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultMarketSubstrates
     */
    struct MarketSubstrates {
        /// @dev marketId => MarketSubstratesStruct
        mapping(uint256 => MarketSubstratesStruct) value;
    }

    /**
     * @notice Manages market-to-fuse mappings and active market tracking
     * @dev Provides efficient market lookup and iteration capabilities
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultBalanceFuses
     *
     * Storage Components:
     * - fuseAddresses: Maps each market to its designated balance fuse
     * - marketIds: Maintains ordered list of active markets for iteration
     * - indexes: Maps market IDs to their position+1 in marketIds array
     *
     * Key Features:
     * - Efficient market-fuse relationship management
     * - Fast market existence validation (index 0 means not present)
     * - Optimized iteration over active markets
     * - Maintains market list integrity
     *
     * Usage:
     * - Market balance tracking and validation
     * - Fuse assignment and management
     * - Market activation/deactivation
     * - Multi-market operations coordination
     *
     * Index Mapping Pattern:
     * - Stored value = actual array index + 1
     * - Value of 0 indicates market not present
     * - To get array index, subtract 1 from stored value
     * - Enables distinction between unset markets and first position
     *
     * Security Notes:
     * - Market IDs must be unique
     * - Index mapping must stay synchronized with array
     * - Fuse addresses must be validated before assignment
     * - Critical for vault's balance tracking system
     */
    struct BalanceFuses {
        /// @dev Maps market IDs to their corresponding balance fuse addresses
        mapping(uint256 marketId => address fuseAddress) fuseAddresses;
        /// @dev Ordered array of active market IDs for efficient iteration
        uint256[] marketIds;
        /// @dev Maps market IDs to their position+1 in the marketIds array (0 means not present)
        mapping(uint256 marketId => uint256 index) indexes;
    }

    /**
     * @notice Manages pre-execution hooks configuration for vault functions
     * @dev Provides efficient hook lookup and management for function-specific pre-execution logic
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultPreHooks
     *
     * Storage Components:
     * - hooksImplementation: Maps function selectors to their hook implementation contracts
     * - selectors: Maintains ordered list of registered function selectors
     * - indexes: Enables O(1) selector existence checks and array access
     *
     * Key Features:
     * - Efficient function-to-hook mapping management
     * - Fast hook implementation lookup
     * - Optimized iteration over registered hooks
     * - Maintains hook registry integrity
     *
     * Usage:
     * - Pre-execution validation and checks
     * - Custom function-specific behavior
     * - Hook registration and management
     * - Cross-function state coordination
     *
     * Security Notes:
     * - Function selectors must be unique
     * - Index mapping must stay synchronized with array
     * - Hook implementations must be validated before assignment
     * - Critical for vault's execution security layer
     */
    struct PreHooksConfig {
        /// @dev Maps function selectors to their corresponding hook implementation addresses
        mapping(bytes4 => address) hooksImplementation;
        /// @dev Ordered array of registered function selectors for efficient iteration
        bytes4[] selectors;
        /// @dev Maps function selectors to their position in the selectors array for O(1) lookup
        mapping(bytes4 selector => uint256 index) indexes;
        /// @dev Maps function selectors and addresses to their corresponding substrate ids
        /// @dev key is keccak256(abi.encodePacked(address, selector))
        mapping(bytes32 key => bytes32[] substrates) substrates;
    }

    /**
     * @notice Tracks dependencies between market balances for atomic updates
     * @dev Maps markets to their dependent markets requiring simultaneous balance updates
     * @custom:storage-location erc7201:io.ipor.BalanceDependenceGraph
     */
    struct DependencyBalanceGraph {
        mapping(uint256 marketId => uint256[] marketIds) dependencyGraph;
    }

    /**
     * @notice Stores ordered list of fuses available for instant withdrawals
     * @dev Order determines withdrawal attempt sequence, same fuse can appear multiple times
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultInstantWithdrawalFusesArray
     */
    struct InstantWithdrawalFuses {
        /// @dev value is a Fuse address used for instant withdrawal
        address[] value;
    }

    /**
     * @notice Stores parameters for instant withdrawal fuse operations
     * @dev Maps fuse+index pairs to their withdrawal configuration parameters
     * @custom:storage-location erc7201:io.ipor.CfgPlasmaVaultInstantWithdrawalFusesParams
     */
    struct InstantWithdrawalFusesParams {
        /// @dev key: fuse address and index in InstantWithdrawalFuses array, value: list of parameters used for instant withdrawal
        /// @dev first param always amount in underlying asset of PlasmaVault, second and next params are specific for the fuse and market
        mapping(bytes32 => bytes32[]) value;
    }

    /**
     * @notice Stores performance fee configuration and recipient data
     * @dev Manages fee percentage and recipient account for performance-based fees
     * @custom:storage-location erc7201:io.ipor.PlasmaVaultPerformanceFeeData
     */
    struct PerformanceFeeData {
        address feeAccount;
        uint16 feeInPercentage;
    }

    /**
     * @notice Stores management fee configuration and time tracking data
     * @dev Manages continuous fee collection with time-based accrual
     * @custom:storage-location erc7201:io.ipor.PlasmaVaultManagementFeeData
     */
    struct ManagementFeeData {
        address feeAccount;
        uint16 feeInPercentage;
        uint32 lastUpdateTimestamp;
    }

    /**
     * @notice Stores address of price oracle middleware for asset valuations
     * @dev Provides standardized price feed access for vault operations
     * @custom:storage-location erc7201:io.ipor.PriceOracleMiddleware
     */
    struct PriceOracleMiddleware {
        address value;
    }

    /**
     * @notice Tracks execution state of vault operations
     * @dev Used as a flag to prevent concurrent execution and manage callbacks
     * @custom:storage-location erc7201:io.ipor.executeRunning
     */
    struct ExecuteState {
        uint256 value;
    }

    /**
     * @notice Stores address of the contract managing withdrawal controls
     * @dev Handles withdrawal permissions, schedules and limits
     * @custom:storage-location erc7201:io.ipor.WithdrawManager
     */
    struct WithdrawManager {
        address manager;
    }

    function getERC4626Storage() internal pure returns (ERC4626Storage storage $) {
        assembly {
            $.slot := ERC4626_STORAGE_LOCATION
        }
    }

    function getERC20CappedStorage() internal pure returns (ERC20CappedStorage storage $) {
        assembly {
            $.slot := ERC20_CAPPED_STORAGE_LOCATION
        }
    }

    function getERC20CappedValidationFlag() internal pure returns (ERC20CappedValidationFlag storage $) {
        assembly {
            $.slot := ERC20_CAPPED_VALIDATION_FLAG
        }
    }

    function getTotalAssets() internal pure returns (TotalAssets storage totalAssets) {
        assembly {
            totalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_ALL_MARKETS
        }
    }

    function getExecutionState() internal pure returns (ExecuteState storage executeRunning) {
        assembly {
            executeRunning.slot := EXECUTE_RUNNING
        }
    }

    function getCallbackHandler() internal pure returns (CallbackHandler storage handler) {
        assembly {
            handler.slot := CALLBACK_HANDLER
        }
    }

    function getDependencyBalanceGraph() internal pure returns (DependencyBalanceGraph storage dependencyBalanceGraph) {
        assembly {
            dependencyBalanceGraph.slot := DEPENDENCY_BALANCE_GRAPH
        }
    }

    function getMarketTotalAssets() internal pure returns (MarketTotalAssets storage marketTotalAssets) {
        assembly {
            marketTotalAssets.slot := PLASMA_VAULT_TOTAL_ASSETS_IN_MARKET
        }
    }

    function getMarketSubstrates() internal pure returns (MarketSubstrates storage marketSubstrates) {
        assembly {
            marketSubstrates.slot := CFG_PLASMA_VAULT_MARKET_SUBSTRATES
        }
    }

    function getBalanceFuses() internal pure returns (BalanceFuses storage balanceFuses) {
        assembly {
            balanceFuses.slot := CFG_PLASMA_VAULT_BALANCE_FUSES
        }
    }

    function getPreHooksConfig() internal pure returns (PreHooksConfig storage preHooksConfig) {
        assembly {
            preHooksConfig.slot := CFG_PLASMA_VAULT_PRE_HOOKS
        }
    }

    function getInstantWithdrawalFusesArray()
        internal
        pure
        returns (InstantWithdrawalFuses storage instantWithdrawalFuses)
    {
        assembly {
            instantWithdrawalFuses.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_ARRAY
        }
    }

    function getInstantWithdrawalFusesParams()
        internal
        pure
        returns (InstantWithdrawalFusesParams storage instantWithdrawalFusesParams)
    {
        assembly {
            instantWithdrawalFusesParams.slot := CFG_PLASMA_VAULT_INSTANT_WITHDRAWAL_FUSES_PARAMS
        }
    }

    function getPriceOracleMiddleware() internal pure returns (PriceOracleMiddleware storage oracle) {
        assembly {
            oracle.slot := PRICE_ORACLE_MIDDLEWARE
        }
    }

    function getPerformanceFeeData() internal pure returns (PerformanceFeeData storage performanceFeeData) {
        assembly {
            performanceFeeData.slot := PLASMA_VAULT_PERFORMANCE_FEE_DATA
        }
    }

    function getManagementFeeData() internal pure returns (ManagementFeeData storage managementFeeData) {
        assembly {
            managementFeeData.slot := PLASMA_VAULT_MANAGEMENT_FEE_DATA
        }
    }

    function getRewardsClaimManagerAddress()
        internal
        pure
        returns (RewardsClaimManagerAddress storage rewardsClaimManagerAddress)
    {
        assembly {
            rewardsClaimManagerAddress.slot := REWARDS_CLAIM_MANAGER_ADDRESS
        }
    }

    function getMarketsLimits() internal pure returns (MarketLimits storage marketLimits) {
        assembly {
            marketLimits.slot := MARKET_LIMITS
        }
    }

    function getWithdrawManager() internal pure returns (WithdrawManager storage withdrawManager) {
        assembly {
            withdrawManager.slot := WITHDRAW_MANAGER
        }
    }
}
