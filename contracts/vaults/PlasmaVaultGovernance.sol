// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FusesLib} from "../libraries/FusesLib.sol";
import {PlasmaVaultConfigLib} from "../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../price_oracle/IPriceOracleMiddleware.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {AssetDistributionProtectionLib, MarketLimit} from "../libraries/AssetDistributionProtectionLib.sol";
import {AccessManagedUpgradeable} from "../managers/access/AccessManagedUpgradeable.sol";
import {CallbackHandlerLib} from "../libraries/CallbackHandlerLib.sol";
import {IPlasmaVaultGovernance} from "../interfaces/IPlasmaVaultGovernance.sol";
import {IIporFusionAccessManager} from "../interfaces/IIporFusionAccessManager.sol";
import {PreHooksLib} from "../handlers/pre_hooks/PreHooksLib.sol";
/// @title Plasma Vault Governance
/// @notice Core governance contract for managing Plasma Vault configuration, security, and operational parameters
/// @dev Inherits AccessManagedUpgradeable for role-based access control and security management
///
/// Key responsibilities:
/// - Market substrate management and validation
/// - Fuse system configuration and control
/// - Fee structure management (performance & management)
/// - Price oracle middleware integration
/// - Access control and permissions
/// - Asset distribution protection
/// - Withdrawal system configuration
/// - Total supply cap management
///
/// Governance functions:
/// - Market configuration and substrate grants
/// - Fuse addition/removal and validation
/// - Fee rate and recipient management
/// - Oracle updates and validation
/// - Access control modifications
/// - Market limits and protection setup
/// - Withdrawal path configuration
///
/// Security considerations:
/// - Role-based access control for all functions
/// - Market validation and protection
/// - Fee caps and recipient validation
/// - Oracle compatibility checks
/// - Fuse system security
///
/// Integration points:
/// - PlasmaVault: Main vault operations
/// - PlasmaVaultBase: Core functionality
/// - Price Oracle: Asset valuation
/// - Access Manager: Permission control
/// - Fuse System: Protocol integrations
/// - Fee Manager: Revenue distribution
///
abstract contract PlasmaVaultGovernance is IPlasmaVaultGovernance, AccessManagedUpgradeable {
    /// @notice Checks if a substrate is granted for a specific market
    /// @param marketId_ The ID of the market to check
    /// @param substrate_ The substrate identifier to verify
    /// @return bool True if the substrate is granted for the market
    /// @dev Validates substrate permissions for market operations
    ///
    /// Substrate validation:
    /// - Confirms if a specific substrate (asset/protocol) is allowed in market
    /// - Essential for market operation validation
    /// - Used during fuse execution checks
    /// - Part of market access control system
    ///
    /// Market context:
    /// - Each market has unique substrate permissions
    /// - Substrates represent:
    ///   - Underlying assets
    ///   - Protocol positions
    ///   - Trading pairs
    ///   - Market-specific identifiers
    ///
    /// Used during:
    /// - Fuse execution validation
    /// - Market operation checks
    /// - Protocol integration verification
    /// - Access control enforcement
    ///
    /// Integration points:
    /// - Balance Fuses: Operation validation
    /// - Market Configuration: Permission checks
    /// - Protocol Integration: Asset validation
    /// - Governance Operations: Market management
    ///
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) external view override returns (bool) {
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(marketId_, substrate_);
    }

    /// @notice Verifies if a fuse contract is registered and supported by the Plasma Vault
    /// @dev Delegates to FusesLib for fuse support validation
    /// - Uses FuseStorageLib mapping to verify fuse registration
    /// - Part of the vault's protocol integration security layer
    /// - Critical for preventing unauthorized protocol interactions
    ///
    /// Storage Pattern:
    /// - Checks FuseStorageLib.Fuses mapping where:
    ///   - Non-zero value indicates supported fuse
    ///   - Value represents (index + 1) in fusesArray
    ///   - Zero value means fuse is not supported
    ///
    /// Integration Context:
    /// - Called before fuse operations in PlasmaVault.execute()
    /// - Used during protocol integration validation
    /// - Part of governance fuse management system
    /// - Supports multi-protocol security checks
    ///
    /// Security Considerations:
    /// - Prevents execution of unauthorized fuses
    /// - Part of vault's protocol access control
    /// - Guards against malicious protocol integrations
    /// - Zero address returns false
    ///
    /// Related Components:
    /// - FusesLib: Core fuse management logic
    /// - FuseStorageLib: Persistent fuse storage
    /// - PlasmaVault: Main execution context
    /// - Protocol-specific fuses (Compound, Aave, etc.)
    ///
    /// @param fuse_ The address of the fuse contract to check
    /// @return bool True if the fuse is supported, false otherwise
    /// @custom:security Non-privileged view function
    function isFuseSupported(address fuse_) external view override returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    /// @notice Checks if a balance fuse is supported for a specific market
    /// @dev Validates if a fuse is configured as the designated balance tracker for a market
    ///
    /// Balance Fuse System:
    /// - Each market can have only one active balance fuse
    /// - Balance fuses track protocol-specific positions
    /// - Provides standardized balance reporting interface
    /// - Essential for market-specific asset tracking
    ///
    /// Integration Context:
    /// - Used during market balance updates
    /// - Part of asset distribution protection
    /// - Supports protocol-specific balance tracking
    /// - Validates balance fuse operations
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.BalanceFuses mapping
    /// - Maps marketId to balance fuse address
    /// - Zero address indicates no balance fuse
    /// - One-to-one market to fuse relationship
    ///
    /// Use Cases:
    /// - Balance calculation validation
    /// - Market position verification
    /// - Protocol integration checks
    /// - Governance operations
    ///
    /// Related Components:
    /// - CompoundV3BalanceFuse
    /// - AaveV3BalanceFuse
    /// - Other protocol-specific balance trackers
    ///
    /// @param marketId_ The ID of the market to check
    /// @param fuse_ The address of the balance fuse
    /// @return bool True if the fuse is the designated balance fuse for the market
    /// @custom:access External view
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) external view override returns (bool) {
        return FusesLib.isBalanceFuseSupported(marketId_, fuse_);
    }

    /// @notice Checks if the market exposure protection system is active
    /// @dev Validates the activation status of market limits through sentinel value
    ///
    /// Protection System:
    /// - Controls enforcement of market exposure limits
    /// - Part of vault's risk management framework
    /// - Protects against over-concentration in markets
    /// - Essential for asset distribution safety
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.MarketsLimits mapping
    /// - Slot 0 reserved for activation sentinel
    /// - Non-zero value in slot 0 indicates active
    /// - Zero value means protection is disabled
    ///
    /// Integration Context:
    /// - Used during all vault operations
    /// - Critical for risk limit enforcement
    /// - Affects market position validations
    /// - Part of governance control system
    ///
    /// Risk Management:
    /// - Prevents excessive market exposure
    /// - Enforces diversification requirements
    /// - Guards against protocol concentration
    /// - Maintains vault stability
    ///
    /// Related Components:
    /// - Asset Distribution Protection System
    /// - Market Limit Configurations
    /// - Balance Validation System
    /// - Governance Controls
    ///
    /// @return bool True if market limits protection is active
    /// @custom:access Public view
    /// @custom:security Non-privileged view function
    function isMarketsLimitsActivated() public view override returns (bool) {
        return AssetDistributionProtectionLib.isMarketsLimitsActivated();
    }

    /// @notice Retrieves all granted substrates for a specific market
    /// @dev Provides access to market's substrate configuration through PlasmaVaultConfigLib
    ///
    /// Substrate System:
    /// - Returns all active substrate identifiers for a market
    /// - Substrates can represent:
    ///   * Asset addresses (converted to bytes32)
    ///   * Protocol-specific vault identifiers
    ///   * Market parameters
    ///   * Configuration values
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.MarketSubstratesStruct
    /// - Maintains ordered list of granted substrates
    /// - Preserves grant operation order
    /// - Maps substrates to their allowance status
    ///
    /// Integration Context:
    /// - Used for market configuration auditing
    /// - Supports governance operations
    /// - Enables UI/external system integration
    /// - Facilitates market setup validation
    ///
    /// Use Cases:
    /// - Market configuration verification
    /// - Protocol integration management
    /// - Asset permission auditing
    /// - System state inspection
    ///
    /// Related Components:
    /// - Market Configuration System
    /// - Substrate Management
    /// - Asset Distribution Protection
    /// - Protocol Integration Layer
    ///
    /// @param marketId_ The ID of the market to query
    /// @return bytes32[] Array of all granted substrate identifiers
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getMarketSubstrates(uint256 marketId_) external view override returns (bytes32[] memory) {
        return PlasmaVaultConfigLib.getMarketSubstrates(marketId_);
    }

    /// @notice Retrieves the complete list of supported fuse contracts
    /// @dev Provides direct access to the fuses array from FuseStorageLib
    ///
    /// Storage Pattern:
    /// - Returns FuseStorageLib.FusesArray contents
    /// - Array indices correspond to (mapping value - 1)
    /// - Maintains parallel structure with fuse mapping
    /// - Order reflects fuse addition sequence
    ///
    /// Integration Context:
    /// - Used for fuse system configuration
    /// - Supports protocol integration auditing
    /// - Enables governance operations
    /// - Facilitates system state inspection
    ///
    /// Fuse System:
    /// - Lists all protocol integration contracts
    /// - Includes both active and balance fuses
    /// - Critical for vault configuration
    /// - No duplicates allowed
    ///
    /// Use Cases:
    /// - Protocol integration verification
    /// - Governance system management
    /// - Fuse system auditing
    /// - Configuration validation
    ///
    /// Related Components:
    /// - FusesLib: Core management logic
    /// - FuseStorageLib: Storage management
    /// - Protocol-specific fuses
    /// - Balance tracking fuses
    ///
    /// @return address[] Array of all supported fuse contract addresses
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getFuses() external view override returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    /// @notice Gets the current price oracle middleware address
    /// @dev Retrieves the address of the price oracle middleware used for asset valuations
    ///
    /// Price Oracle System:
    /// - Provides standardized price feeds for vault assets
    /// - Must support USD as quote currency
    /// - Critical for asset valuation and calculations
    /// - Required for market operations
    ///
    /// Integration Context:
    /// - Used by balance fuses for market valuations
    /// - Essential for withdrawal calculations
    /// - Required for performance tracking
    /// - Core component for share price determination
    ///
    /// Valuation Use Cases:
    /// - Asset price discovery
    /// - Market balance calculations
    /// - Fee computations
    /// - Share price updates
    ///
    /// Related Components:
    /// - Balance Fuses: Market valuations
    /// - Asset Distribution Protection
    /// - Performance Fee System
    /// - Share Price Calculator
    ///
    /// @return address The price oracle middleware contract address
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getPriceOracleMiddleware() external view override returns (address) {
        return PlasmaVaultLib.getPriceOracleMiddleware();
    }

    /// @notice Gets the access manager contract address
    /// @dev Retrieves the address of the contract managing role-based access control
    ///
    /// Access Control System:
    /// - Core component for role-based permissions
    /// - Manages vault access rights
    /// - Controls governance operations
    /// - Enforces security policies
    ///
    /// Role Management:
    /// - ATOMIST_ROLE: Core governance operations
    /// - FUSE_MANAGER_ROLE: Protocol integration control
    /// - OWNER_ROLE: System administration
    ///
    /// Integration Context:
    /// - Used for permission validation
    /// - Governance operation control
    /// - Protocol security enforcement
    /// - Role assignment management
    ///
    /// Security Features:
    /// - Role-based access control
    /// - Permission validation
    /// - Operation authorization
    /// - Execution delay enforcement
    ///
    /// Related Components:
    /// - IIporFusionAccessManager
    /// - AccessManagedUpgradeable
    /// - Governance System
    /// - Security Framework
    ///
    /// @return address The access manager contract address
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getAccessManagerAddress() external view override returns (address) {
        return authority();
    }

    /// @notice Gets the rewards claim manager address
    /// @dev Retrieves the address of the contract managing reward claims and distributions
    ///
    /// Rewards System:
    /// - Handles protocol reward claims
    /// - Manages reward token distributions
    /// - Tracks claimable rewards
    /// - Coordinates reward strategies
    ///
    /// Integration Context:
    /// - Used during reward claim operations
    /// - Part of total asset calculations
    /// - Affects performance metrics
    /// - Supports protocol incentives
    ///
    /// System Features:
    /// - Protocol reward claiming
    /// - Reward distribution management
    /// - Token reward tracking
    /// - Performance accounting
    ///
    /// Configuration Notes:
    /// - Can be zero address (rewards disabled)
    /// - Critical for reward accounting
    /// - Affects total asset calculations
    /// - Impacts performance metrics
    ///
    /// Related Components:
    /// - Protocol Reward Systems
    /// - Asset Valuation Calculator
    /// - Performance Tracking
    /// - Governance Configuration
    ///
    /// @return address The rewards claim manager contract address
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getRewardsClaimManagerAddress() external view override returns (address) {
        return PlasmaVaultLib.getRewardsClaimManagerAddress();
    }

    /// @notice Gets the ordered list of instant withdrawal fuses
    /// @dev Retrieves the configured withdrawal path sequence from PlasmaVaultLib
    ///
    /// Withdrawal System:
    /// - Returns ordered array of withdrawal fuse addresses
    /// - Order determines withdrawal attempt sequence
    /// - Same fuse can appear multiple times with different params
    /// - Empty array if no withdrawal paths configured
    ///
    /// Integration Context:
    /// - Used during withdrawal operations
    /// - Part of withdrawal path validation
    /// - Supports withdrawal strategy execution
    /// - Coordinates fuse interactions
    ///
    /// System Features:
    /// - Ordered withdrawal path execution
    /// - Multiple withdrawal strategies
    /// - Protocol-specific withdrawals
    /// - Fallback path support
    ///
    /// Configuration Notes:
    /// - Order is critical for withdrawal efficiency
    /// - Multiple entries of same fuse allowed
    /// - Each fuse needs corresponding params
    /// - Used with getInstantWithdrawalFusesParams
    ///
    /// Related Components:
    /// - Withdrawal Execution System
    /// - Protocol-specific Fuses
    /// - Balance Validation
    /// - Fuse Parameter Management
    ///
    /// @return address[] Array of withdrawal fuse addresses in priority order
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getInstantWithdrawalFuses() external view override returns (address[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFuses();
    }

    /// @notice Gets parameters for a specific instant withdrawal fuse instance
    /// @dev Retrieves withdrawal configuration parameters for specific fuse execution
    ///
    /// Parameter Structure:
    /// - params[0]: Reserved for withdrawal amount (set during execution)
    /// - params[1+]: Fuse-specific parameters such as:
    ///   * Market identifiers
    ///   * Asset addresses
    ///   * Slippage tolerances
    ///   * Protocol-specific configuration
    ///
    /// Storage Pattern:
    /// - Uses keccak256(abi.encodePacked(fuse_, index_)) as key
    /// - Allows same fuse to have different params at different indices
    /// - Supports protocol-specific parameter requirements
    /// - Maintains parameter ordering
    ///
    /// Integration Context:
    /// - Used during withdrawal execution
    /// - Part of withdrawal path configuration
    /// - Supports fuse interaction setup
    /// - Validates withdrawal parameters
    ///
    /// Security Considerations:
    /// - Parameters must match fuse expectations
    /// - Index must correspond to withdrawal sequence
    /// - First parameter reserved for withdrawal amount
    /// - Critical for proper withdrawal execution
    ///
    /// Related Components:
    /// - Instant Withdrawal System
    /// - Protocol-specific Fuses
    /// - Parameter Validation
    /// - Withdrawal Execution
    ///
    /// @param fuse_ The address of the withdrawal fuse contract
    /// @param index_ The position of the fuse in the withdrawal sequence
    /// @return bytes32[] Array of parameters configured for this fuse instance
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getInstantWithdrawalFusesParams(
        address fuse_,
        uint256 index_
    ) external view override returns (bytes32[] memory) {
        return PlasmaVaultLib.getInstantWithdrawalFusesParams(fuse_, index_);
    }

    /// @notice Gets the market limit percentage for a specific market
    /// @dev Retrieves market-specific allocation limit from PlasmaVaultStorageLib
    ///
    /// Market Limits System:
    /// - Enforces market-specific allocation limits
    /// - Prevents over-concentration in single markets
    /// - Part of risk management through diversification
    /// - Limits stored in basis points (1e18 = 100%)
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.MarketLimits mapping
    /// - Maps marketId to percentage limit
    /// - Zero limit for marketId 0 deactivates all limits
    /// - Non-zero limit for marketId 0 activates limit system
    ///
    /// Integration Context:
    /// - Used by AssetDistributionProtectionLib
    /// - Referenced during balance updates
    /// - Part of risk management system
    /// - Critical for market operations
    ///
    /// Risk Management:
    /// - Controls market exposure
    /// - Enforces diversification
    /// - Prevents concentration risk
    /// - Maintains system stability
    ///
    /// @param marketId_ The ID of the market to query
    /// @return uint256 The market limit percentage (1e18 = 100%)
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getMarketLimit(uint256 marketId_) external view override returns (uint256) {
        return PlasmaVaultStorageLib.getMarketsLimits().limitInPercentage[marketId_];
    }

    /// @notice Gets the dependency balance graph for a specific market
    /// @dev Retrieves the array of market IDs that depend on the queried market
    ///
    /// Dependency System:
    /// - Tracks dependencies between market balances
    /// - Ensures atomic balance updates
    /// - Maintains consistency across related markets
    /// - Manages complex market relationships
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.DependencyBalanceGraph
    /// - Maps marketId to array of dependent market IDs
    /// - Dependencies are unidirectional (A->B doesn't imply B->A)
    /// - Empty array means no dependencies
    ///
    /// Integration Context:
    /// - Used during balance updates
    /// - Critical for market synchronization
    /// - Part of withdrawal validation
    /// - Supports rebalancing operations
    ///
    /// Example Dependencies:
    /// - Lending markets depending on underlying assets
    /// - LP token markets depending on constituent tokens
    /// - Derivative markets depending on base assets
    /// - Protocol-specific market relationships
    ///
    /// @param marketId_ The ID of the market to query
    /// @return uint256[] Array of market IDs that depend on this market
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getDependencyBalanceGraph(uint256 marketId_) external view override returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_];
    }

    /// @notice Gets the total supply cap for the vault
    /// @dev Retrieves the configured maximum total supply limit from PlasmaVaultLib
    ///
    /// Supply Cap System:
    /// - Enforces maximum vault size
    /// - Limits total value locked (TVL)
    /// - Guards against excessive concentration
    /// - Supports gradual scaling
    ///
    /// Storage Pattern:
    /// - Uses PlasmaVaultStorageLib.ERC20CappedStorage
    /// - Stores cap in underlying asset decimals
    /// - Can be temporarily bypassed for fees
    /// - Critical for deposit control
    ///
    /// Integration Context:
    /// - Used during deposit validation
    /// - Referenced in share minting
    /// - Part of fee minting checks
    /// - Affects deposit availability
    ///
    /// Risk Management:
    /// - Controls maximum vault exposure
    /// - Manages protocol risk
    /// - Supports controlled growth
    /// - Protects market stability
    ///
    /// Related Components:
    /// - ERC4626 Implementation
    /// - Fee Minting System
    /// - Deposit Controls
    /// - Risk Parameters
    ///
    /// @return uint256 The maximum total supply in underlying asset decimals
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getTotalSupplyCap() external view override returns (uint256) {
        return PlasmaVaultLib.getTotalSupplyCap();
    }

    /// @notice Retrieves the list of all active markets with registered balance fuses
    /// @dev Provides access to the ordered array of active market IDs from BalanceFuses storage
    ///
    /// Market Tracking System:
    /// - Returns complete list of markets with balance fuses
    /// - Order reflects market registration sequence
    /// - List maintained by add/remove operations
    /// - Critical for market state management
    ///
    /// Storage Access:
    /// - Reads from PlasmaVaultStorageLib.BalanceFuses.marketIds
    /// - No storage modifications
    /// - O(1) operation for array access
    /// - Returns complete array reference
    ///
    /// Integration Context:
    /// - Used for market balance updates
    /// - Supports multi-market operations
    /// - Essential for balance synchronization
    /// - Part of asset distribution system
    ///
    /// Array Properties:
    /// - No duplicate market IDs
    /// - Order may change during removals
    /// - Maintained through governance operations
    /// - Empty array possible if no active markets
    ///
    /// Use Cases:
    /// - Market balance validation
    /// - Asset distribution checks
    /// - Protocol state monitoring
    /// - Governance operations
    ///
    /// Related Components:
    /// - Balance Fuse System
    /// - Market Management
    /// - Asset Protection
    /// - Protocol Operations
    ///
    /// @return uint256[] Array of active market IDs with registered balance fuses
    /// @custom:access External view
    /// @custom:security Non-privileged view function
    function getActiveMarketsInBalanceFuses() external view returns (uint256[] memory) {
        return FusesLib.getActiveMarketsInBalanceFuses();
    }

    /// @notice Adds a balance fuse for a specific market
    /// @dev Manages market-specific balance fuse assignments through FusesLib
    ///
    /// Balance Fuse System:
    /// - Associates balance tracking fuse with market
    /// - Each market can have only one active balance fuse
    /// - Balance fuses track protocol-specific positions
    /// - Essential for standardized balance reporting
    ///
    /// Storage Updates:
    /// - Updates PlasmaVaultStorageLib.BalanceFuses mapping
    /// - Maps marketId to balance fuse address
    /// - Prevents duplicate fuse assignments
    /// - Emits BalanceFuseAdded event
    ///
    /// Integration Context:
    /// - Used during market setup and configuration
    /// - Part of protocol integration process
    /// - Critical for market balance tracking
    /// - Supports asset distribution protection
    ///
    /// Security Considerations:
    /// - Only callable by FUSE_MANAGER_ROLE
    /// - Validates fuse address
    /// - Prevents duplicate assignments
    /// - Critical for market balance integrity
    ///
    /// Related Components:
    /// - Balance Fuse Contracts
    /// - Market Balance System
    /// - Asset Distribution Protection
    /// - Protocol Integration Layer
    ///
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to add
    /// @custom:access FUSE_MANAGER_ROLE restricted
    /// @custom:events Emits BalanceFuseAdded when successful
    function addBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        _addBalanceFuse(marketId_, fuse_);
    }

    /// @notice Removes a balance fuse from a specific market
    /// @dev Manages the removal of market-specific balance fuse assignments through FusesLib
    ///
    /// Balance Fuse System:
    /// - Removes association between market and balance fuse
    /// - Clears balance tracking for protocol-specific positions
    /// - Must match current assigned fuse for market
    /// - Critical for market reconfiguration
    ///
    /// Storage Updates:
    /// - Updates PlasmaVaultStorageLib.BalanceFuses mapping
    /// - Removes marketId to balance fuse mapping
    /// - Validates current fuse assignment
    /// - Emits BalanceFuseRemoved event
    ///
    /// Integration Context:
    /// - Used during market reconfiguration
    /// - Part of protocol migration process
    /// - Supports balance tracking updates
    /// - Required for market deactivation
    ///
    /// Security Considerations:
    /// - Only callable by FUSE_MANAGER_ROLE
    /// - Validates fuse address matches current
    /// - Requires zero balance before removal
    /// - Critical for market integrity
    ///
    /// Related Components:
    /// - Balance Fuse Contracts
    /// - Market Balance System
    /// - Asset Distribution Protection
    /// - Protocol Integration Layer
    ///
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to remove
    /// @custom:access FUSE_MANAGER_ROLE restricted
    /// @custom:events Emits BalanceFuseRemoved when successful
    function removeBalanceFuse(uint256 marketId_, address fuse_) external override restricted {
        FusesLib.removeBalanceFuse(marketId_, fuse_);
    }

    /// @notice Grants substrates to a specific market
    /// @dev Manages market-specific substrate permissions through PlasmaVaultConfigLib
    ///
    /// Substrate System:
    /// - Assigns protocol-specific identifiers to markets
    /// - Substrates can represent:
    ///   * Asset addresses (converted to bytes32)
    ///   * Protocol-specific vault identifiers
    ///   * Market parameters
    ///   * Trading pair configurations
    ///
    /// Storage Pattern:
    /// - Updates PlasmaVaultStorageLib.MarketSubstratesStruct
    /// - Maintains ordered list of granted substrates
    /// - Maps substrates to their allowance status
    /// - Preserves grant operation order
    ///
    /// Integration Context:
    /// - Used during market setup and configuration
    /// - Part of protocol integration process
    /// - Critical for market permissions
    /// - Supports multi-protocol operations
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Validates substrate format
    /// - Prevents duplicate grants
    /// - Critical for market access control
    ///
    /// Related Components:
    /// - Market Configuration System
    /// - Protocol Integration Layer
    /// - Access Control System
    /// - Balance Validation
    ///
    /// @param marketId_ The ID of the market
    /// @param substrates_ Array of substrates to grant
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:events Emits MarketSubstrateGranted for each substrate
    function grantMarketSubstrates(uint256 marketId_, bytes32[] calldata substrates_) external override restricted {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @notice Updates dependency balance graphs for multiple markets
    /// @dev Manages market balance dependencies and their relationships in the vault system
    ///
    /// Dependency System:
    /// - Manages relationships between market balances
    /// - Supports complex market interdependencies
    /// - Critical for maintaining balance consistency
    /// - Enables atomic balance updates
    ///
    /// Storage Pattern:
    /// - Updates PlasmaVaultStorageLib.DependencyBalanceGraph
    /// - Maps marketId to array of dependent market IDs
    /// - Dependencies are directional (A->B doesn't imply B->A)
    /// - Overwrites existing dependencies
    ///
    /// Integration Context:
    /// - Used during market configuration
    /// - Essential for balance synchronization
    /// - Supports protocol integrations
    /// - Enables complex market strategies
    ///
    /// Use Cases:
    /// - Lending market dependencies
    /// - LP token relationships
    /// - Derivative market links
    /// - Cross-protocol dependencies
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Validates array length matching
    /// - Critical for balance integrity
    /// - Affects withdrawal validation
    ///
    /// Related Components:
    /// - Balance Tracking System
    /// - Market Configuration
    /// - Withdrawal Validation
    /// - Protocol Integration Layer
    ///
    /// @param marketIds_ Array of market IDs to update
    /// @param dependencies_ Array of dependency arrays for each market
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for balance consistency
    function updateDependencyBalanceGraphs(
        uint256[] memory marketIds_,
        uint256[][] memory dependencies_
    ) external override restricted {
        uint256 marketIdsLength = marketIds_.length;
        if (marketIdsLength != dependencies_.length) {
            revert Errors.WrongArrayLength();
        }
        for (uint256 i; i < marketIdsLength; ++i) {
            PlasmaVaultLib.updateDependencyBalanceGraph(marketIds_[i], dependencies_[i]);
        }
    }

    /// @notice Configures the instant withdrawal fuses. Order of the fuse is important, as it will be used in the same order during the instant withdrawal process
    /// @dev Manages the configuration of instant withdrawal paths and their execution sequence
    ///
    /// Withdrawal System:
    /// - Configures ordered sequence of withdrawal attempts
    /// - Each fuse represents a withdrawal strategy
    /// - Same fuse can be used multiple times with different params
    /// - Order determines execution priority
    ///
    /// Configuration Structure:
    /// - fuses_[].fuse: Protocol-specific withdrawal contract
    /// - fuses_[].params: Configuration parameters where:
    ///   * params[0]: Reserved for withdrawal amount
    ///   * params[1+]: Strategy-specific parameters
    ///
    /// Storage Updates:
    /// - Updates PlasmaVaultStorageLib withdrawal configuration
    /// - Stores ordered fuse sequence
    /// - Maps fuse parameters to sequence index
    /// - Maintains execution order
    ///
    /// Integration Context:
    /// - Critical for withdrawal path optimization
    /// - Supports multiple protocol withdrawals
    /// - Enables complex withdrawal strategies
    /// - Facilitates liquidity management
    ///
    /// Security Considerations:
    /// - Only callable by CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE
    /// - Validates fuse addresses
    /// - Parameter validation per fuse
    /// - Order impacts withdrawal efficiency
    ///
    /// Related Components:
    /// - Withdrawal Execution System
    /// - Protocol-specific Fuses
    /// - Parameter Management
    /// - Liquidity Optimization
    ///
    /// @param fuses_ Array of instant withdrawal fuse configurations
    /// @custom:access CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE restricted
    /// @custom:security Critical for withdrawal path security
    function configureInstantWithdrawalFuses(
        InstantWithdrawalFusesParamsStruct[] calldata fuses_
    ) external override restricted {
        PlasmaVaultLib.configureInstantWithdrawalFuses(fuses_);
    }

    /// @notice Adds new fuses to the vault
    /// @dev Manages the registration of protocol integration fuses through FusesLib
    ///
    /// Fuse System:
    /// - Registers protocol-specific integration contracts
    /// - Each fuse represents a unique protocol interaction
    /// - Maintains vault's supported protocol list
    /// - Critical for protocol integration security
    ///
    /// Storage Updates:
    /// - Updates FuseStorageLib.Fuses mapping
    /// - Appends to FuseStorageLib.FusesArray
    /// - Assigns sequential indices to fuses
    /// - Emits FuseAdded event per fuse
    ///
    /// Integration Context:
    /// - Used during protocol integration setup
    /// - Enables new protocol interactions
    /// - Part of vault expansion process
    /// - Supports protocol upgrades
    ///
    /// Security Considerations:
    /// - Only callable by FUSE_MANAGER_ROLE
    /// - Validates fuse addresses
    /// - Prevents duplicate registrations
    /// - Critical for protocol security
    ///
    /// Related Components:
    /// - Protocol-specific Fuses
    /// - FusesLib: Core management
    /// - FuseStorageLib: Storage
    /// - PlasmaVault: Execution
    ///
    /// @param fuses_ Array of fuse addresses to add
    /// @custom:access FUSE_MANAGER_ROLE restricted
    /// @custom:events Emits FuseAdded for each fuse
    function addFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    /// @notice Removes fuses from the vault
    /// @dev Manages removal of protocol integration fuses using swap-and-pop pattern
    ///
    /// Fuse System:
    /// - Removes protocol-specific integration contracts
    /// - Updates vault's supported protocol list
    /// - Maintains storage consistency
    /// - Uses efficient array management
    ///
    /// Storage Updates:
    /// - Updates FuseStorageLib.Fuses mapping
    /// - Maintains FuseStorageLib.FusesArray
    /// - Uses swap-and-pop for array efficiency
    /// - Emits FuseRemoved event per fuse
    ///
    /// Integration Context:
    /// - Used during protocol removal
    /// - Part of vault maintenance
    /// - Supports protocol upgrades
    /// - Critical for security updates
    ///
    /// Storage Pattern:
    /// - Moves last array element to removed position
    /// - Updates mapping for moved element
    /// - Clears removed fuse's mapping entry
    /// - Pops last array element
    ///
    /// Security Considerations:
    /// - Only callable by FUSE_MANAGER_ROLE
    /// - Validates fuse existence
    /// - Maintains mapping-array consistency
    /// - Critical for protocol security
    ///
    /// Gas Optimization:
    /// - Uses swap-and-pop vs shifting
    /// - Minimizes storage operations
    /// - Three SSTORE per removal:
    ///   1. Update moved element mapping
    ///   2. Clear removed mapping
    ///   3. Pop array
    ///
    /// @param fuses_ Array of fuse addresses to remove
    /// @custom:access FUSE_MANAGER_ROLE restricted
    /// @custom:events Emits FuseRemoved for each fuse
    /// @custom:security Critical for protocol integration security
    function removeFuses(address[] calldata fuses_) external override restricted {
        for (uint256 i; i < fuses_.length; ++i) {
            FusesLib.removeFuse(fuses_[i]);
        }
    }

    /// @notice Sets the price oracle middleware address
    /// @dev Updates the price oracle middleware while ensuring quote currency compatibility
    ///
    /// Oracle System:
    /// - Core component for asset price discovery
    /// - Must maintain consistent quote currency
    /// - Critical for vault valuations
    /// - Enables standardized pricing
    ///
    /// Validation Requirements:
    /// - New oracle must match existing:
    ///   * Quote currency (e.g., USD)
    ///   * Quote currency decimals
    /// - Prevents incompatible oracle updates
    /// - Maintains valuation consistency
    ///
    /// Integration Context:
    /// - Used by balance fuses
    /// - Critical for:
    ///   * Share price calculation
    ///   * Performance tracking
    ///   * Fee computation
    ///   * Market valuations
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Validates oracle compatibility
    /// - Critical for system integrity
    /// - Affects all price-dependent operations
    ///
    /// Error Conditions:
    /// - Reverts if quote currency mismatch
    /// - Reverts if decimal precision mismatch
    /// - Reverts with UnsupportedPriceOracleMiddleware
    ///
    /// @param priceOracleMiddleware_ The new price oracle middleware address
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for price discovery integrity
    function setPriceOracleMiddleware(address priceOracleMiddleware_) external override restricted {
        IPriceOracleMiddleware oldPriceOracleMiddleware = IPriceOracleMiddleware(
            PlasmaVaultLib.getPriceOracleMiddleware()
        );
        IPriceOracleMiddleware newPriceOracleMiddleware = IPriceOracleMiddleware(priceOracleMiddleware_);

        if (oldPriceOracleMiddleware.QUOTE_CURRENCY() != newPriceOracleMiddleware.QUOTE_CURRENCY()) {
            revert Errors.UnsupportedPriceOracleMiddleware();
        }

        PlasmaVaultLib.setPriceOracleMiddleware(priceOracleMiddleware_);
    }

    /// @notice Sets the rewards claim manager address
    /// @dev Updates rewards manager configuration and emits event
    ///
    /// Configuration Options:
    /// - Non-zero address: Enables reward claiming functionality
    ///   * Activates protocol reward claiming
    ///   * Enables reward token distributions
    ///   * Tracks claimable rewards
    ///   * Manages reward strategies
    ///
    /// - Zero address: Disables reward claiming system
    ///   * Deactivates reward claiming
    ///   * Suspends reward distributions
    ///   * Maintains existing balances
    ///   * Preserves historical data
    ///
    /// Integration Context:
    /// - Used during protocol reward setup
    /// - Affects total asset calculations
    /// - Part of performance tracking
    /// - Impacts fee computations
    ///
    /// System Features:
    /// - Protocol reward claiming
    /// - Reward distribution management
    /// - Token reward tracking
    /// - Performance accounting
    ///
    /// Security Considerations:
    /// - Only callable by TECH_REWARDS_CLAIM_MANAGER_ROLE which is assigned to RewardsClaimManager contract itself
    /// - RewardsClaimManager must explicitly allow this method execution through its own logic
    /// - Critical for reward system integrity
    /// - Affects total asset calculations
    /// - Impacts performance metrics
    /// - Cannot be changed if RewardsClaimManager contract does not permit it
    ///
    /// Related Components:
    /// - Protocol Reward Systems
    /// - Asset Valuation Calculator
    /// - Performance Tracking
    /// - Fee Computation Logic
    /// - RewardsClaimManager Contract
    ///
    /// @param rewardsClaimManagerAddress_ The new rewards claim manager address
    /// @custom:access TECH_REWARDS_CLAIM_MANAGER_ROLE (held by RewardsClaimManager) restricted
    /// @custom:events Emits RewardsClaimManagerAddressChanged
    /// @custom:security Critical for reward system integrity
    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) public override restricted {
        PlasmaVaultLib.setRewardsClaimManagerAddress(rewardsClaimManagerAddress_);
    }

    /// @notice Sets up market limits for asset distribution protection
    /// @dev Configures maximum exposure limits for multiple markets in the vault system
    ///
    /// Limit System:
    /// - Enforces maximum allocation per market
    /// - Uses fixed-point percentages (1e18 = 100%)
    /// - Prevents over-concentration risk
    /// - Critical for risk distribution
    ///
    /// Configuration Rules:
    /// - Market ID 0 is reserved (system control)
    /// - Limits must not exceed 100%
    /// - Each market can have unique limit
    /// - Supports multiple market updates
    ///
    /// Storage Updates:
    /// - Updates PlasmaVaultStorageLib.MarketsLimits
    /// - Maps marketId to percentage limit
    /// - Emits MarketLimitUpdated events
    /// - Maintains limit configurations
    ///
    /// Error Conditions:
    /// - Reverts if marketId is 0 (WrongMarketId)
    /// - Reverts if limit > 100% (MarketLimitSetupInPercentageIsTooHigh)
    /// - Validates each market configuration
    /// - Ensures limit consistency
    ///
    /// Integration Context:
    /// - Part of risk management framework
    /// - Affects market operation validation
    /// - Critical for vault stability
    /// - Supports protocol diversification
    ///
    /// Related Components:
    /// - Asset Distribution Protection
    /// - Market Balance Tracking
    /// - Risk Management System
    /// - Limit Validation Logic
    ///
    /// @param marketsLimits_ Array of market limit configurations
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:events Emits MarketLimitUpdated for each market
    /// @custom:security Critical for risk management system
    function setupMarketsLimits(MarketLimit[] calldata marketsLimits_) external override restricted {
        AssetDistributionProtectionLib.setupMarketsLimits(marketsLimits_);
    }

    /// @notice Activates the markets limits protection, by default it is deactivated
    /// @dev Enables the market exposure protection system through sentinel value
    ///
    /// Protection System:
    /// - Controls enforcement of market exposure limits
    /// - Uses slot 0 as activation sentinel
    /// - Critical for risk management activation
    /// - Affects all market operations
    ///
    /// Storage Updates:
    /// - Sets PlasmaVaultStorageLib.MarketsLimits slot 0 to 1
    /// - Enables limit validation in checkLimits()
    /// - Activates percentage-based exposure controls
    /// - Emits MarketsLimitsActivated event
    ///
    /// Integration Context:
    /// - Required after market limit configuration
    /// - Affects all subsequent vault operations
    /// - Part of risk management framework
    /// - Enables asset distribution protection
    ///
    /// System Features:
    /// - Market exposure control
    /// - Risk distribution enforcement
    /// - Protocol concentration limits
    /// - Balance validation checks
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Requires prior limit configuration
    /// - Critical for risk management
    /// - Affects all market interactions
    ///
    /// Related Components:
    /// - Asset Distribution Protection
    /// - Market Balance System
    /// - Risk Management Framework
    /// - Limit Validation Logic
    ///
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:events Emits MarketsLimitsActivated
    /// @custom:security Critical for risk management activation
    function activateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.activateMarketsLimits();
    }

    /// @notice Deactivates the markets limits protection
    /// @dev Disables the market exposure protection system by clearing sentinel value
    ///
    /// Protection System:
    /// - Disables enforcement of market exposure limits
    /// - Clears slot 0 activation sentinel
    /// - Emergency risk control feature
    /// - Affects all market operations
    ///
    /// Storage Updates:
    /// - Sets PlasmaVaultStorageLib.MarketsLimits slot 0 to 0
    /// - Disables limit validation in checkLimits()
    /// - Suspends percentage-based exposure controls
    /// - Emits MarketsLimitsDeactivated event
    ///
    /// Integration Context:
    /// - Emergency risk management tool
    /// - Affects all vault operations
    /// - Bypasses market limits
    /// - Enables unrestricted positions
    ///
    /// Use Cases:
    /// - Emergency market conditions
    /// - System maintenance
    /// - Market rebalancing
    /// - Protocol migration
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Removes all limit protections
    /// - Should be used with caution
    /// - Critical system state change
    ///
    /// Related Components:
    /// - Asset Distribution Protection
    /// - Market Balance System
    /// - Risk Management Framework
    /// - Emergency Controls
    ///
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:events Emits MarketsLimitsDeactivated
    /// @custom:security Critical for risk management system
    function deactivateMarketsLimits() public override restricted {
        AssetDistributionProtectionLib.deactivateMarketsLimits();
    }

    /// @notice Updates the callback handler configuration
    /// @dev Manages callback handler mappings for vault operations
    ///
    /// Callback System:
    /// - Maps function signatures to handler contracts
    /// - Enables protocol-specific callbacks
    /// - Supports operation hooks
    /// - Manages execution flow
    ///
    /// Configuration Components:
    /// - handler_: Contract implementing callback logic
    /// - sender_: Authorized callback initiator
    /// - sig_: Target function signature (4 bytes)
    ///
    /// Storage Updates:
    /// - Updates CallbackHandlerLib mappings
    /// - Links handler to sender and signature
    /// - Enables callback execution
    /// - Maintains handler configurations
    ///
    /// Integration Context:
    /// - Used for protocol-specific operations
    /// - Supports custom execution flows
    /// - Enables external integrations
    /// - Manages operation hooks
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Validates handler address
    /// - Critical for execution flow
    /// - Affects operation security
    ///
    /// Related Components:
    /// - CallbackHandlerLib
    /// - Protocol Integration Layer
    /// - Operation Execution System
    /// - Security Framework
    ///
    /// @param handler_ The callback handler address
    /// @param sender_ The sender address
    /// @param sig_ The function signature
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for execution flow integrity
    function updateCallbackHandler(address handler_, address sender_, bytes4 sig_) external override restricted {
        CallbackHandlerLib.updateCallbackHandler(handler_, sender_, sig_);
    }

    /// @notice Sets the total supply cap for the vault
    /// @dev Updates the vault's total supply limit while enforcing validation rules
    ///
    /// Supply Cap System:
    /// - Enforces maximum vault size
    /// - Controls total value locked (TVL)
    /// - Guards against excessive concentration
    /// - Supports gradual scaling
    ///
    /// Validation Requirements:
    /// - Must be non-zero value
    /// - Must be sufficient for operations
    /// - Should consider asset decimals
    /// - Must accommodate fee minting
    ///
    /// Storage Updates:
    /// - Updates PlasmaVaultStorageLib.ERC20CappedStorage
    /// - Stores cap in underlying asset decimals
    /// - Affects deposit availability
    /// - Impacts share minting limits
    ///
    /// Integration Context:
    /// - Used during deposit validation
    /// - Affects share minting operations
    /// - Part of risk management system
    /// - Critical for vault scaling
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Critical for vault size control
    /// - Affects deposit availability
    /// - Impacts risk parameters
    ///
    /// Related Components:
    /// - ERC4626 Implementation
    /// - Deposit Control System
    /// - Fee Minting Logic
    /// - Risk Management Framework
    ///
    /// @param cap_ The new total supply cap in underlying asset decimals
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for vault capacity management
    function setTotalSupplyCap(uint256 cap_) external override restricted {
        PlasmaVaultLib.setTotalSupplyCap(cap_);
    }

    /// @notice Converts the vault to a public vault
    /// @dev Modifies access control to enable public deposit and minting operations
    ///
    /// Access Control Updates:
    /// - Sets PUBLIC_ROLE for:
    ///   * mint() function
    ///   * deposit() function
    ///   * depositWithPermit() function
    /// - Enables unrestricted access to deposit operations
    /// - Maintains other access restrictions
    ///
    /// Integration Context:
    /// - Used during vault lifecycle transitions
    /// - Part of access control system
    /// - Enables public participation
    /// - Critical for vault accessibility
    ///
    /// System Impact:
    /// - Allows public deposits
    /// - Enables direct minting
    /// - Supports permit deposits
    /// - Maintains security controls
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Irreversible operation
    /// - Affects deposit permissions
    /// - Critical for vault access
    ///
    /// Related Components:
    /// - IporFusionAccessManager
    /// - Access Control System
    /// - Deposit Functions
    /// - Permission Management
    ///
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for vault accessibility
    function convertToPublicVault() external override restricted {
        IIporFusionAccessManager(authority()).convertToPublicVault(address(this));
    }

    /// @notice Enables transfer of shares
    /// @dev Modifies access control to enable share transfer functionality
    ///
    /// Access Control Updates:
    /// - Sets PUBLIC_ROLE for:
    ///   * transfer() function
    ///   * transferFrom() function
    /// - Enables unrestricted share transfers
    /// - Maintains other access restrictions
    /// - Critical for share transferability
    ///
    /// Integration Context:
    /// - Used during vault lifecycle transitions
    /// - Part of access control system
    /// - Enables secondary market trading
    /// - Supports share liquidity
    ///
    /// System Impact:
    /// - Allows share transfers between accounts
    /// - Enables delegated transfers
    /// - Supports trading integrations
    /// - Maintains transfer restrictions
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Irreversible operation
    /// - Affects share transferability
    /// - Critical for vault liquidity
    ///
    /// Related Components:
    /// - IporFusionAccessManager
    /// - Access Control System
    /// - Transfer Functions
    /// - Permission Management
    ///
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for share transferability
    function enableTransferShares() external override restricted {
        IIporFusionAccessManager(authority()).enableTransferShares(address(this));
    }

    /// @notice Sets minimal execution delays for roles
    /// @dev Configures timelock delays for role-based operations through IporFusionAccessManager
    ///
    /// Timelock System:
    /// - Sets minimum delay between scheduling and execution
    /// - Role-specific delay requirements
    /// - Critical for governance security
    /// - Enforces operation timelocks
    ///
    /// Configuration Components:
    /// - rolesIds_: Array of role identifiers
    /// - delays_: Corresponding minimum delays
    /// - Validates delay requirements
    /// - Maintains role security
    ///
    /// Integration Context:
    /// - Part of access control system
    /// - Affects operation execution
    /// - Supports governance security
    /// - Enables controlled changes
    ///
    /// Security Features:
    /// - Role-based execution delays
    /// - Operation scheduling
    /// - Timelock enforcement
    /// - Governance protection
    ///
    /// Security Considerations:
    /// - Only callable by OWNER_ROLE
    /// - Validates delay parameters
    /// - Critical for role security
    /// - Affects operation timing
    ///
    /// Related Components:
    /// - IporFusionAccessManager
    /// - RoleExecutionTimelockLib
    /// - Access Control System
    /// - Governance Framework
    ///
    /// @param rolesIds_ Array of role IDs to configure
    /// @param delays_ Array of corresponding minimum delays
    /// @custom:access OWNER_ROLE restricted
    /// @custom:security Critical for governance timelock system
    function setMinimalExecutionDelaysForRoles(
        uint64[] calldata rolesIds_,
        uint256[] calldata delays_
    ) external override restricted {
        IIporFusionAccessManager(authority()).setMinimalExecutionDelaysForRoles(rolesIds_, delays_);
    }

    /// @notice Sets or updates pre-hook implementations for function selectors
    /// @dev Manages the configuration of pre-execution hooks through PreHooksLib
    ///
    /// Pre-Hook System:
    /// - Maps function selectors to pre-hook implementations
    /// - Configures substrate parameters for each hook
    /// - Supports addition, update, and removal operations
    /// - Maintains hook execution order
    ///
    /// Configuration Components:
    /// - selectors_: Function signatures requiring pre-hooks
    /// - implementations_: Corresponding hook contract addresses
    /// - substrates_: Configuration parameters for each hook
    ///
    /// Storage Updates:
    /// - Updates PreHooksLib configuration
    /// - Maintains selector to implementation mapping
    /// - Stores substrate configurations
    /// - Preserves hook execution order
    ///
    /// Operation Types:
    /// - Add new pre-hook: Maps new selector to implementation
    /// - Update existing: Changes implementation or substrates
    /// - Remove pre-hook: Sets implementation to address(0)
    /// - Batch operations supported
    ///
    /// Security Considerations:
    /// - Only callable by ATOMIST_ROLE
    /// - Validates array length matching
    /// - Prevents invalid selector configurations
    /// - Critical for execution security
    ///
    /// Integration Context:
    /// - Used for vault operation customization
    /// - Supports protocol-specific validations
    /// - Enables complex operation flows
    /// - Critical for vault extensibility
    ///
    /// Related Components:
    /// - PreHooksLib: Core management
    /// - Pre-hook Implementations
    /// - Vault Operations
    /// - Security Framework
    ///
    /// @param selectors_ Array of function selectors to configure
    /// @param implementations_ Array of pre-hook implementation addresses
    /// @param substrates_ Array of substrate configurations for each hook
    /// @custom:access ATOMIST_ROLE restricted
    /// @custom:security Critical for vault operation security
    function setPreHookImplementations(
        bytes4[] calldata selectors_,
        address[] calldata implementations_,
        bytes32[][] calldata substrates_
    ) external restricted {
        PreHooksLib.setPreHookImplementations(selectors_, implementations_, substrates_);
    }

    function getPreHookSelectors() external view returns (bytes4[] memory) {
        return PreHooksLib.getPreHookSelectors();
    }

    function getPreHookImplementation(bytes4 selector_) external view returns (address) {
        return PreHooksLib.getPreHookImplementation(selector_);
    }

    function _addFuse(address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addFuse(fuse_);
    }

    // TODO: add tests for this functions
    /// @dev only owner
    function addManager(uint256 managerId_, address managerAddress_) external restricted {
        PlasmaVaultConfigLib.addManager(managerId_, managerAddress_);
    }

    // TODO: add tests for this functions
    /// @dev only admin
    function updateManager(uint256 managerId_, address managerAddress_) external restricted {
        PlasmaVaultConfigLib.updateManager(managerId_, managerAddress_);
    }

    function getManager(uint256 managerId_) external view returns (address) {
        return PlasmaVaultConfigLib.getManager(managerId_);
    }

    function getManagerIds() external view returns (uint256[] memory) {
        return PlasmaVaultConfigLib.getManagerIds();
    }

    /// @notice Internal helper to add a balance fuse
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to add
    /// @dev Validates fuse address and adds it to the market
    /// @custom:access Internal
    /// @notice Internal helper to add a balance fuse
    /// @param marketId_ The ID of the market
    /// @param fuse_ The address of the fuse to add
    /// @dev Validates fuse address and adds it to the market
    /// @custom:access Internal
    function _addBalanceFuse(uint256 marketId_, address fuse_) internal {
        if (fuse_ == address(0)) {
            revert Errors.WrongAddress();
        }
        FusesLib.addBalanceFuse(marketId_, fuse_);
    }
}
