// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Errors} from "./errors/Errors.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {FusesLib} from "./FusesLib.sol";

/// @title InstantWithdrawalFusesParamsStruct
/// @notice A technical struct used to configure instant withdrawal fuses and their parameters in the Plasma Vault system
/// @dev This struct is used primarily in configureInstantWithdrawalFuses function to set up withdrawal paths
struct InstantWithdrawalFusesParamsStruct {
    /// @notice The address of the fuse contract that handles a specific withdrawal path
    /// @dev Must be a valid and supported fuse contract address that implements instant withdrawal logic
    address fuse;
    /// @notice Array of parameters specific to the fuse's withdrawal logic
    /// @dev Parameter structure:
    /// - params[0]: Always represents the withdrawal amount in underlying token decimals (set during withdrawal, not during configuration)
    /// - params[1+]: Additional fuse-specific parameters such as:
    ///   - Asset addresses
    ///   - Market IDs
    ///   - Slippage tolerances
    ///   - Protocol-specific parameters
    /// @dev The same fuse can appear multiple times with different params for different withdrawal paths
    bytes32[] params;
}

/// @title Plasma Vault Library
/// @notice Core library responsible for managing the Plasma Vault's state and operations
/// @dev Provides centralized management of vault operations, fees, configuration and state updates
///
/// Key responsibilities:
/// - Asset management and accounting
/// - Fee configuration and calculations
/// - Market balance tracking and updates
/// - Withdrawal system configuration
/// - Access control and execution state
/// - Price oracle integration
/// - Rewards claim management
library PlasmaVaultLib {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @dev Hard CAP for the performance fee in percentage - 50%
    uint256 public constant PERFORMANCE_MAX_FEE_IN_PERCENTAGE = 5000;

    /// @dev Hard CAP for the management fee in percentage - 5%
    uint256 public constant MANAGEMENT_MAX_FEE_IN_PERCENTAGE = 500;

    /// @dev The offset for the underlying asset decimals in the Plasma Vault
    uint8 public constant DECIMALS_OFFSET = 2;

    error InvalidPerformanceFee(uint256 feeInPercentage);
    error InvalidManagementFee(uint256 feeInPercentage);

    event InstantWithdrawalFusesConfigured(InstantWithdrawalFusesParamsStruct[] fuses);
    event PriceOracleMiddlewareChanged(address newPriceOracleMiddleware);
    event PerformanceFeeDataConfigured(address feeAccount, uint256 feeInPercentage);
    event ManagementFeeDataConfigured(address feeAccount, uint256 feeInPercentage);
    event RewardsClaimManagerAddressChanged(address newRewardsClaimManagerAddress);
    event DependencyBalanceGraphChanged(uint256 marketId, uint256[] newDependenceGraph);
    event WithdrawManagerChanged(address newWithdrawManager);
    event TotalSupplyCapChanged(uint256 newTotalSupplyCap);

    /// @notice Gets the total assets in the vault for all markets
    /// @dev Retrieves the total value of assets across all integrated markets and protocols
    /// @return uint256 The total assets in the vault, represented in decimals of the underlying asset
    ///
    /// This function:
    /// - Returns the raw total of assets without considering:
    ///   - Unrealized management fees
    ///   - Unrealized performance fees
    ///   - Pending rewards
    ///   - Current vault balance
    ///
    /// Used by:
    /// - PlasmaVault.totalAssets() for share price calculations
    /// - Fee calculations and accrual
    /// - Asset distribution checks
    /// - Market limit validations
    ///
    /// @dev Important: This value represents only the tracked assets in markets,
    /// for full vault assets see PlasmaVault._getGrossTotalAssets()
    function getTotalAssetsInAllMarkets() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getTotalAssets().value;
    }

    /// @notice Gets the total assets in the vault for a specific market
    /// @param marketId_ The ID of the market to query
    /// @return uint256 The total assets in the vault for the market, represented in decimals of the underlying asset
    ///
    /// @dev This function provides market-specific asset tracking and is used for:
    /// - Market balance validation
    /// - Asset distribution checks
    /// - Market limit enforcement
    /// - Balance dependency resolution
    ///
    /// Important considerations:
    /// - Returns raw balance without considering fees
    /// - Value is updated by balance fuses during market interactions
    /// - Used in conjunction with market dependency graphs
    /// - Critical for maintaining proper asset distribution across markets
    ///
    /// Integration points:
    /// - Balance Fuses: Update market balances
    /// - Asset Distribution Protection: Check market limits
    /// - Withdrawal System: Verify available assets
    /// - Market Dependencies: Track related market updates
    function getTotalAssetsInMarket(uint256 marketId_) internal view returns (uint256) {
        return PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_];
    }

    /// @notice Gets the dependency balance graph for a specific market
    /// @param marketId_ The ID of the market to query
    /// @return uint256[] Array of market IDs that depend on the queried market
    ///
    /// @dev The dependency balance graph is critical for maintaining consistent state across related markets:
    /// - Ensures atomic balance updates across dependent markets
    /// - Prevents inconsistent states in interconnected protocols
    /// - Manages complex market relationships
    ///
    /// Use cases:
    /// - Market balance updates
    /// - Withdrawal validations
    /// - Asset rebalancing
    /// - Protocol integrations
    ///
    /// Example dependencies:
    /// - Lending markets depending on underlying asset markets
    /// - LP token markets depending on constituent token markets
    /// - Derivative markets depending on base asset markets
    ///
    /// Important considerations:
    /// - Dependencies are unidirectional (A->B doesn't imply B->A)
    /// - Empty array means no dependencies
    /// - Order of dependencies may matter for some operations
    /// - Used by _checkBalanceFusesDependencies() during balance updates
    function getDependencyBalanceGraph(uint256 marketId_) internal view returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_];
    }

    /// @notice Updates the dependency balance graph for a specific market
    /// @param marketId_ The ID of the market to update
    /// @param newDependenceGraph_ Array of market IDs that should depend on this market
    /// @dev Updates the market dependency relationships and emits an event
    ///
    /// This function:
    /// - Overwrites existing dependencies for the market
    /// - Establishes new dependency relationships
    /// - Triggers event for dependency tracking
    ///
    /// Security considerations:
    /// - Only callable by authorized governance functions
    /// - Critical for maintaining market balance consistency
    /// - Must prevent circular dependencies
    /// - Should validate market existence
    ///
    /// Common update scenarios:
    /// - Adding new market dependencies
    /// - Removing obsolete dependencies
    /// - Modifying existing dependency chains
    /// - Protocol integration changes
    ///
    /// @dev Important: Changes to dependency graph affect:
    /// - Balance update order
    /// - Withdrawal validations
    /// - Market rebalancing operations
    /// - Protocol interaction flows
    function updateDependencyBalanceGraph(uint256 marketId_, uint256[] memory newDependenceGraph_) internal {
        PlasmaVaultStorageLib.getDependencyBalanceGraph().dependencyGraph[marketId_] = newDependenceGraph_;
        emit DependencyBalanceGraphChanged(marketId_, newDependenceGraph_);
    }

    /// @notice Adds or subtracts an amount from the total assets in the Plasma Vault
    /// @param amount_ The signed amount to adjust total assets by, represented in decimals of the underlying asset
    /// @dev Updates the global total assets tracker based on market operations
    ///
    /// Function behavior:
    /// - Positive amount: Increases total assets
    /// - Negative amount: Decreases total assets
    /// - Zero amount: No effect
    ///
    /// Used during:
    /// - Market balance updates
    /// - Fee realizations
    /// - Asset rebalancing
    /// - Withdrawal processing
    ///
    /// Security considerations:
    /// - Handles signed integers safely using SafeCast
    /// - Only called during validated operations
    /// - Must maintain accounting consistency
    /// - Critical for share price calculations
    ///
    /// @dev Important: This function affects:
    /// - Total vault valuation
    /// - Share price calculations
    /// - Fee calculations
    /// - Asset distribution checks
    function addToTotalAssetsInAllMarkets(int256 amount_) internal {
        if (amount_ < 0) {
            PlasmaVaultStorageLib.getTotalAssets().value -= (-amount_).toUint256();
        } else {
            PlasmaVaultStorageLib.getTotalAssets().value += amount_.toUint256();
        }
    }

    /// @notice Updates the total assets in the Plasma Vault for a specific market
    /// @param marketId_ The ID of the market to update
    /// @param newTotalAssetsInUnderlying_ The new total assets value for the market
    /// @return deltaInUnderlying The net change in assets (positive or negative), represented in underlying decimals
    /// @dev Updates market-specific asset tracking and calculates the change in total assets
    ///
    /// Function behavior:
    /// - Stores new total assets for the market
    /// - Calculates delta between old and new values
    /// - Returns signed delta for total asset updates
    ///
    /// Used during:
    /// - Balance fuse updates
    /// - Market rebalancing
    /// - Protocol interactions
    /// - Asset redistribution
    ///
    /// Security considerations:
    /// - Handles asset value transitions safely
    /// - Uses SafeCast for integer conversions
    /// - Must be called within proper market context
    /// - Critical for maintaining accurate balances
    ///
    /// Integration points:
    /// - Called by balance fuses after market operations
    /// - Used in _updateMarketsBalances for batch updates
    /// - Triggers market limit validations
    /// - Affects total asset calculations
    ///
    /// @dev Important: The returned delta is used by:
    /// - addToTotalAssetsInAllMarkets
    /// - Asset distribution protection checks
    /// - Market balance event emissions
    function updateTotalAssetsInMarket(
        uint256 marketId_,
        uint256 newTotalAssetsInUnderlying_
    ) internal returns (int256 deltaInUnderlying) {
        uint256 oldTotalAssetsInUnderlying = PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_];
        PlasmaVaultStorageLib.getMarketTotalAssets().value[marketId_] = newTotalAssetsInUnderlying_;
        deltaInUnderlying = newTotalAssetsInUnderlying_.toInt256() - oldTotalAssetsInUnderlying.toInt256();
    }

    /// @notice Gets the management fee configuration data
    /// @return managementFeeData The current management fee configuration containing:
    ///         - feeAccount: Address receiving management fees
    ///         - feeInPercentage: Current fee rate (basis points, 1/10000)
    ///         - lastUpdateTimestamp: Last time fees were realized
    /// @dev Retrieves the current management fee settings from storage
    ///
    /// Fee structure:
    /// - Continuous time-based fee on assets under management (AUM)
    /// - Fee percentage limited by MANAGEMENT_MAX_FEE_IN_PERCENTAGE (5%)
    /// - Fees accrue linearly over time
    /// - Realized during vault operations
    ///
    /// Used for:
    /// - Fee calculations in totalAssets()
    /// - Fee realization during operations
    /// - Management fee distribution
    /// - Governance fee adjustments
    ///
    /// Integration points:
    /// - PlasmaVault._realizeManagementFee()
    /// - PlasmaVault.totalAssets()
    /// - FeeManager contract
    /// - Governance configuration
    ///
    /// @dev Important: Management fees:
    /// - Are calculated based on total vault assets
    /// - Affect share price calculations
    /// - Must be realized before major vault operations
    /// - Are distributed to configured fee recipients
    function getManagementFeeData()
        internal
        view
        returns (PlasmaVaultStorageLib.ManagementFeeData memory managementFeeData)
    {
        return PlasmaVaultStorageLib.getManagementFeeData();
    }

    /// @notice Configures the management fee settings for the vault
    /// @param feeAccount_ The address that will receive management fees
    /// @param feeInPercentage_ The management fee rate in basis points (100 = 1%)
    /// @dev Updates fee configuration and emits event
    ///
    /// Parameter requirements:
    /// - feeAccount_: Must be non-zero address. The address of the technical Management Fee Account that will receive the management fee collected by the Plasma Vault and later on distributed to IPOR DAO and recipients by FeeManager
    /// - feeInPercentage_: Must not exceed MANAGEMENT_MAX_FEE_IN_PERCENTAGE (5%)
    ///
    /// Fee account types:
    /// - FeeManager contract: Distributes fees to IPOR DAO and other recipients
    /// - EOA/MultiSig: Receives fees directly without distribution
    /// - Technical account: Temporary fee collection before distribution
    ///
    /// Fee percentage format:
    /// - Uses 2 decimal places (basis points)
    /// - Examples:
    ///   - 10000 = 100%
    ///   - 100 = 1%
    ///   - 1 = 0.01%
    ///
    /// Security considerations:
    /// - Only callable by authorized governance functions
    /// - Validates fee percentage against maximum limit
    /// - Emits event for tracking changes
    /// - Critical for vault economics
    ///
    /// @dev Important: Changes affect:
    /// - Future fee calculations
    /// - Share price computations
    /// - Vault revenue distribution
    /// - Total asset calculations
    function configureManagementFee(address feeAccount_, uint256 feeInPercentage_) internal {
        if (feeAccount_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (feeInPercentage_ > MANAGEMENT_MAX_FEE_IN_PERCENTAGE) {
            revert InvalidManagementFee(feeInPercentage_);
        }

        PlasmaVaultStorageLib.ManagementFeeData storage managementFeeData = PlasmaVaultStorageLib
            .getManagementFeeData();

        managementFeeData.feeAccount = feeAccount_;
        managementFeeData.feeInPercentage = feeInPercentage_.toUint16();

        emit ManagementFeeDataConfigured(feeAccount_, feeInPercentage_);
    }

    /// @notice Gets the performance fee configuration data
    /// @return performanceFeeData The current performance fee configuration containing:
    ///         - feeAccount: The address of the technical Performance Fee Account that will receive the performance fee collected by the Plasma Vault and later on distributed to IPOR DAO and recipients by FeeManager
    ///         - feeInPercentage: Current fee rate (basis points, 1/10000)
    /// @dev Retrieves the current performance fee settings from storage
    ///
    /// Fee structure:
    /// - Charged on positive vault performance
    /// - Fee percentage limited by PERFORMANCE_MAX_FEE_IN_PERCENTAGE (50%)
    /// - Calculated on realized gains only
    /// - Applied during execute() operations
    ///
    /// Used for:
    /// - Performance fee calculations
    /// - Fee realization during profitable operations
    /// - Performance fee distribution
    /// - Governance fee adjustments
    ///
    /// Integration points:
    /// - PlasmaVault._addPerformanceFee()
    /// - PlasmaVault.execute()
    /// - FeeManager contract
    /// - Governance configuration
    ///
    /// @dev Important: Performance fees:
    /// - Only charged on positive performance
    /// - Calculated based on profit since last fee realization
    /// - Minted as new vault shares
    /// - Distributed to configured fee recipients
    function getPerformanceFeeData()
        internal
        view
        returns (PlasmaVaultStorageLib.PerformanceFeeData memory performanceFeeData)
    {
        return PlasmaVaultStorageLib.getPerformanceFeeData();
    }

    /// @notice Configures the performance fee settings for the vault
    /// @param feeAccount_ The address that will receive performance fees
    /// @param feeInPercentage_ The performance fee rate in basis points (100 = 1%)
    /// @dev Updates fee configuration and emits event
    ///
    /// Parameter requirements:
    /// - feeAccount_: Must be non-zero address. The address of the technical Performance Fee Account that will receive the performance fee collected by the Plasma Vault and later on distributed to IPOR DAO and recipients by FeeManager
    /// - feeInPercentage_: Must not exceed PERFORMANCE_MAX_FEE_IN_PERCENTAGE (50%)
    ///
    /// Fee account types:
    /// - FeeManager contract: Distributes fees to IPOR DAO and other recipients
    /// - EOA/MultiSig: Receives fees directly without distribution
    /// - Technical account: Temporary fee collection before distribution
    ///
    /// Fee percentage format:
    /// - Uses 2 decimal places (basis points)
    /// - Examples:
    ///   - 10000 = 100%
    ///   - 100 = 1%
    ///   - 1 = 0.01%
    ///
    /// Security considerations:
    /// - Only callable by authorized governance functions
    /// - Validates fee percentage against maximum limit
    /// - Emits event for tracking changes
    /// - Critical for vault incentive structure
    ///
    /// @dev Important: Changes affect:
    /// - Profit sharing calculations
    /// - Alpha incentive alignment
    /// - Vault performance metrics
    /// - Revenue distribution model
    function configurePerformanceFee(address feeAccount_, uint256 feeInPercentage_) internal {
        if (feeAccount_ == address(0)) {
            revert Errors.WrongAddress();
        }
        if (feeInPercentage_ > PERFORMANCE_MAX_FEE_IN_PERCENTAGE) {
            revert InvalidPerformanceFee(feeInPercentage_);
        }

        PlasmaVaultStorageLib.PerformanceFeeData storage performanceFeeData = PlasmaVaultStorageLib
            .getPerformanceFeeData();

        performanceFeeData.feeAccount = feeAccount_;
        performanceFeeData.feeInPercentage = feeInPercentage_.toUint16();

        emit PerformanceFeeDataConfigured(feeAccount_, feeInPercentage_);
    }

    /// @notice Updates the management fee timestamp for fee accrual tracking
    /// @dev Updates lastUpdateTimestamp to current block timestamp for fee calculations
    ///
    /// Function behavior:
    /// - Sets lastUpdateTimestamp to current block.timestamp
    /// - Used to mark points of fee realization
    /// - Critical for time-based fee calculations
    ///
    /// Called during:
    /// - Fee realization operations
    /// - Deposit transactions
    /// - Withdrawal transactions
    /// - Share minting/burning
    ///
    /// Integration points:
    /// - PlasmaVault._realizeManagementFee()
    /// - PlasmaVault.deposit()
    /// - PlasmaVault.withdraw()
    /// - PlasmaVault.mint()
    ///
    /// @dev Important considerations:
    /// - Must be called after fee realization
    /// - Affects future fee calculations
    /// - Uses uint32 for timestamp storage
    /// - Critical for fee accounting accuracy
    function updateManagementFeeData() internal {
        PlasmaVaultStorageLib.ManagementFeeData storage feeData = PlasmaVaultStorageLib.getManagementFeeData();
        feeData.lastUpdateTimestamp = block.timestamp.toUint32();
    }

    /// @notice Gets the ordered list of instant withdrawal fuses
    /// @return address[] Array of fuse addresses in withdrawal priority order
    /// @dev Retrieves the configured withdrawal path sequence
    ///
    /// Function behavior:
    /// - Returns ordered array of fuse addresses
    /// - Empty array if no withdrawal paths configured
    /// - Order determines withdrawal attempt sequence
    /// - Same fuse can appear multiple times with different params
    ///
    /// Used during:
    /// - Withdrawal operations
    /// - Instant withdrawal processing
    /// - Withdrawal path validation
    /// - Withdrawal strategy execution
    ///
    /// Integration points:
    /// - PlasmaVault._withdrawFromMarkets()
    /// - Withdrawal execution logic
    /// - Balance validation
    /// - Fuse interaction coordination
    ///
    /// @dev Important considerations:
    /// - Order is critical for withdrawal efficiency
    /// - Multiple entries of same fuse allowed
    /// - Each fuse needs corresponding params
    /// - Used in conjunction with getInstantWithdrawalFusesParams
    function getInstantWithdrawalFuses() internal view returns (address[] memory) {
        return PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;
    }

    /// @notice Gets the parameters for a specific instant withdrawal fuse at a given index
    /// @param fuse_ The address of the withdrawal fuse contract
    /// @param index_ The position of the fuse in the withdrawal sequence
    /// @return bytes32[] Array of parameters configured for this fuse instance
    /// @dev Retrieves withdrawal configuration parameters for specific fuse execution
    ///
    /// Parameter structure:
    /// - params[0]: Reserved for withdrawal amount (set during execution)
    /// - params[1+]: Fuse-specific parameters such as:
    ///   - Market identifiers
    ///   - Asset addresses
    ///   - Slippage tolerances
    ///   - Protocol-specific configuration
    ///
    /// Storage pattern:
    /// - Uses keccak256(abi.encodePacked(fuse_, index_)) as key
    /// - Allows same fuse to have different params at different indices
    /// - Supports protocol-specific parameter requirements
    ///
    /// Used during:
    /// - Withdrawal execution
    /// - Parameter validation
    /// - Withdrawal path configuration
    /// - Fuse interaction setup
    ///
    /// @dev Important considerations:
    /// - Parameters must match fuse expectations
    /// - Index must correspond to getInstantWithdrawalFuses array
    /// - First parameter reserved for withdrawal amount
    /// - Critical for proper withdrawal execution
    function getInstantWithdrawalFusesParams(address fuse_, uint256 index_) internal view returns (bytes32[] memory) {
        return
            PlasmaVaultStorageLib.getInstantWithdrawalFusesParams().value[keccak256(abi.encodePacked(fuse_, index_))];
    }

    /// @notice Configures the instant withdrawal fuse sequence and parameters
    /// @param fuses_ Array of fuse configurations with their respective parameters
    /// @dev Sets up withdrawal paths and their execution parameters
    ///
    /// Configuration process:
    /// - Creates ordered list of withdrawal fuses
    /// - Stores parameters for each fuse instance, in most cases are substrates used for instant withdraw
    /// - Validates fuse support status
    /// - Updates storage and emits event
    ///
    /// Parameter validation:
    /// - Each fuse must be supported
    /// - Parameters must match fuse requirements
    /// - Fuse order determines execution priority
    /// - Same fuse can appear multiple times
    ///
    /// Storage updates:
    /// - Clears existing configuration
    /// - Stores new fuse sequence
    /// - Maps parameters to fuse+index combinations
    /// - Maintains parameter ordering
    ///
    /// Security considerations:
    /// - Only callable by authorized governance
    /// - Validates all fuse addresses
    /// - Prevents invalid configurations
    /// - Critical for withdrawal security
    ///
    /// @dev Important: Configuration affects:
    /// - Withdrawal path selection
    /// - Execution sequence
    /// - Protocol interactions
    /// - Withdrawal efficiency
    ///
    /// Common configurations:
    /// - Multiple paths through same protocol
    /// - Different slippage per path
    /// - Market-specific parameters
    /// - Fallback withdrawal routes
    function configureInstantWithdrawalFuses(InstantWithdrawalFusesParamsStruct[] calldata fuses_) internal {
        address[] memory fusesList = new address[](fuses_.length);

        PlasmaVaultStorageLib.InstantWithdrawalFusesParams storage instantWithdrawalFusesParams = PlasmaVaultStorageLib
            .getInstantWithdrawalFusesParams();

        bytes32 key;

        for (uint256 i; i < fuses_.length; ++i) {
            if (!FusesLib.isFuseSupported(fuses_[i].fuse)) {
                revert FusesLib.FuseUnsupported(fuses_[i].fuse);
            }

            fusesList[i] = fuses_[i].fuse;
            key = keccak256(abi.encodePacked(fuses_[i].fuse, i));

            delete instantWithdrawalFusesParams.value[key];

            for (uint256 j; j < fuses_[i].params.length; ++j) {
                instantWithdrawalFusesParams.value[key].push(fuses_[i].params[j]);
            }
        }

        delete PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value;

        PlasmaVaultStorageLib.getInstantWithdrawalFusesArray().value = fusesList;

        emit InstantWithdrawalFusesConfigured(fuses_);
    }

    /// @notice Gets the Price Oracle Middleware address
    /// @return address The current price oracle middleware contract address
    /// @dev Retrieves the address of the price oracle middleware used for asset valuations
    ///
    /// Price Oracle Middleware:
    /// - Provides standardized price feeds for vault assets
    /// - Must support USD as quote currency
    /// - Critical for asset valuation and calculations
    /// - Required for market operations
    ///
    /// Used during:
    /// - Asset valuation calculations
    /// - Market balance updates
    /// - Fee computations
    /// - Share price determinations
    ///
    /// Integration points:
    /// - Balance fuses for market valuations
    /// - Withdrawal calculations
    /// - Performance tracking
    /// - Asset distribution checks
    ///
    /// @dev Important considerations:
    /// - Must be properly initialized
    /// - Critical for vault operations
    /// - Required for accurate share pricing
    /// - Core component for market interactions
    function getPriceOracleMiddleware() internal view returns (address) {
        return PlasmaVaultStorageLib.getPriceOracleMiddleware().value;
    }

    /// @notice Sets the Price Oracle Middleware address for the vault
    /// @param priceOracleMiddleware_ The new price oracle middleware contract address
    /// @dev Updates the price oracle middleware and emits event
    ///
    /// Validation requirements:
    /// - Must support USD as quote currency
    /// - Must maintain same quote currency decimals
    /// - Must be compatible with existing vault operations
    /// - Address must be non-zero
    ///
    /// Security considerations:
    /// - Only callable by authorized governance
    /// - Critical for vault operations
    /// - Must validate oracle compatibility
    /// - Affects all price-dependent operations
    ///
    /// Integration impacts:
    /// - Asset valuations
    /// - Share price calculations
    /// - Market balance updates
    /// - Fee computations
    ///
    /// @dev Important: Changes affect:
    /// - All price-dependent calculations
    /// - Market operations
    /// - Withdrawal validations
    /// - Performance tracking
    ///
    /// Called during:
    /// - Initial vault setup
    /// - Oracle upgrades
    /// - Protocol improvements
    /// - Emergency oracle changes
    function setPriceOracleMiddleware(address priceOracleMiddleware_) internal {
        PlasmaVaultStorageLib.getPriceOracleMiddleware().value = priceOracleMiddleware_;
        emit PriceOracleMiddlewareChanged(priceOracleMiddleware_);
    }

    /// @notice Gets the Rewards Claim Manager address
    /// @return address The current rewards claim manager contract address
    /// @dev Retrieves the address of the contract managing reward claims and distributions
    ///
    /// Rewards Claim Manager:
    /// - Handles protocol reward claims
    /// - Manages reward token distributions
    /// - Tracks claimable rewards
    /// - Coordinates reward strategies
    ///
    /// Used during:
    /// - Reward claim operations
    /// - Total asset calculations
    /// - Fee computations
    /// - Performance tracking
    ///
    /// Integration points:
    /// - Protocol reward systems
    /// - Asset valuation calculations
    /// - Performance fee assessments
    /// - Governance operations
    ///
    /// @dev Important considerations:
    /// - Can be zero address (rewards disabled)
    /// - Critical for reward accounting
    /// - Affects total asset calculations
    /// - Impacts performance metrics
    function getRewardsClaimManagerAddress() internal view returns (address) {
        return PlasmaVaultStorageLib.getRewardsClaimManagerAddress().value;
    }

    /// @notice Sets the Rewards Claim Manager address for the vault
    /// @param rewardsClaimManagerAddress_ The new rewards claim manager contract address
    /// @dev Updates rewards manager configuration and emits event
    ///
    /// Configuration options:
    /// - Non-zero address: Enables reward claiming functionality
    /// - Zero address: Disables reward claiming system
    ///
    /// Security considerations:
    /// - Only callable by authorized governance
    /// - Critical for reward system operation
    /// - Affects total asset calculations
    /// - Impacts performance metrics
    ///
    /// Integration impacts:
    /// - Protocol reward claiming
    /// - Asset valuation calculations
    /// - Performance tracking
    /// - Fee computations
    ///
    /// @dev Important: Changes affect:
    /// - Reward claiming capability
    /// - Total asset calculations
    /// - Performance measurements
    /// - Protocol integrations
    ///
    /// Called during:
    /// - Initial vault setup
    /// - Rewards system upgrades
    /// - Protocol improvements
    /// - Emergency system changes
    function setRewardsClaimManagerAddress(address rewardsClaimManagerAddress_) internal {
        PlasmaVaultStorageLib.getRewardsClaimManagerAddress().value = rewardsClaimManagerAddress_;
        emit RewardsClaimManagerAddressChanged(rewardsClaimManagerAddress_);
    }

    /// @notice Gets the total supply cap for the vault
    /// @return uint256 The maximum allowed total supply in underlying asset decimals
    /// @dev Retrieves the configured supply cap that limits total vault shares
    ///
    /// Supply cap usage:
    /// - Enforces maximum vault size
    /// - Limits total value locked (TVL)
    /// - Guards against excessive concentration
    /// - Supports gradual scaling
    ///
    /// Used during:
    /// - Deposit validation
    /// - Share minting checks
    /// - Fee minting operations
    /// - Governance monitoring
    ///
    /// Integration points:
    /// - ERC4626 deposit/mint functions
    /// - Fee realization operations
    /// - Governance configuration
    /// - Risk management systems
    ///
    /// @dev Important considerations:
    /// - Cap applies to total shares outstanding
    /// - Can be temporarily bypassed for fees
    /// - Critical for risk management
    /// - Affects deposit availability
    function getTotalSupplyCap() internal view returns (uint256) {
        return PlasmaVaultStorageLib.getERC20CappedStorage().cap;
    }

    /// @notice Sets the total supply cap for the vault
    /// @param cap_ The new maximum total supply in underlying asset decimals
    /// @dev Updates the vault's total supply limit and validates input
    ///
    /// Validation requirements:
    /// - Must be non-zero value
    /// - Must be sufficient for expected vault operations
    /// - Should consider asset decimals
    /// - Must accommodate fee minting
    ///
    /// Security considerations:
    /// - Only callable by authorized governance
    /// - Critical for vault size control
    /// - Affects deposit availability
    /// - Impacts risk management
    ///
    /// Integration impacts:
    /// - Deposit operations
    /// - Share minting limits
    /// - Fee realization
    /// - TVL management
    ///
    /// @dev Important: Changes affect:
    /// - Maximum vault capacity
    /// - Deposit availability
    /// - Fee minting headroom
    /// - Risk parameters
    ///
    /// Called during:
    /// - Initial vault setup
    /// - Capacity adjustments
    /// - Growth management
    /// - Risk parameter updates
    function setTotalSupplyCap(uint256 cap_) internal {
        if (cap_ == 0) {
            revert Errors.WrongValue();
        }
        PlasmaVaultStorageLib.getERC20CappedStorage().cap = cap_;
        emit TotalSupplyCapChanged(cap_);
    }

    /// @notice Controls validation of the total supply cap
    /// @param flag_ The validation control flag (0 = enabled, 1 = disabled)
    /// @dev Manages temporary bypassing of supply cap checks for fee minting
    ///
    /// Flag values:
    /// - 0: Supply cap validation enabled (default)
    ///   - Enforces maximum supply limit
    ///   - Applies to deposits and mints
    ///   - Maintains TVL controls
    ///
    /// - 1: Supply cap validation disabled
    ///   - Allows exceeding supply cap
    ///   - Used during fee minting
    ///   - Temporary state only
    ///
    /// Used during:
    /// - Performance fee minting
    /// - Management fee realization
    /// - Emergency operations
    /// - System maintenance
    ///
    /// Security considerations:
    /// - Only callable by authorized functions
    /// - Should be re-enabled after fee operations
    /// - Critical for supply control
    /// - Temporary bypass only
    ///
    /// @dev Important: State affects:
    /// - Supply cap enforcement
    /// - Fee minting operations
    /// - Deposit availability
    /// - System security
    function setTotalSupplyCapValidation(uint256 flag_) internal {
        PlasmaVaultStorageLib.getERC20CappedValidationFlag().value = flag_;
    }

    /// @notice Checks if the total supply cap validation is enabled
    /// @return bool True if validation is enabled (flag = 0), false if disabled (flag = 1)
    /// @dev Provides current state of supply cap enforcement
    ///
    /// Validation states:
    /// - Enabled (true):
    ///   - Normal operation mode
    ///   - Enforces supply cap limits
    ///   - Required for deposits/mints
    ///   - Default state
    ///
    /// - Disabled (false):
    ///   - Temporary bypass mode
    ///   - Allows exceeding cap
    ///   - Used for fee minting
    ///   - Special operations only
    ///
    /// Used during:
    /// - Deposit validation
    /// - Share minting checks
    /// - Fee operations
    /// - System monitoring
    ///
    /// @dev Important considerations:
    /// - Should generally be enabled
    /// - Temporary disable for fees only
    /// - Critical for supply control
    /// - Check before cap-sensitive operations
    function isTotalSupplyCapValidationEnabled() internal view returns (bool) {
        return PlasmaVaultStorageLib.getERC20CappedValidationFlag().value == 0;
    }

    /// @notice Sets the execution state to started for Alpha operations
    /// @dev Marks the beginning of a multi-action execution sequence
    ///
    /// Execution state usage:
    /// - Tracks active Alpha operations
    /// - Enables multi-action sequences
    /// - Prevents concurrent executions
    /// - Maintains operation atomicity
    ///
    /// Used during:
    /// - Alpha strategy execution
    /// - Complex market operations
    /// - Multi-step transactions
    /// - Protocol interactions
    ///
    /// Security considerations:
    /// - Only callable by authorized Alpha
    /// - Must be paired with executeFinished
    /// - Critical for operation integrity
    /// - Prevents execution overlap
    ///
    /// @dev Important: State affects:
    /// - Operation validation
    /// - Reentrancy protection
    /// - Transaction boundaries
    /// - Error handling
    function executeStarted() internal {
        PlasmaVaultStorageLib.getExecutionState().value = 1;
    }

    /// @notice Sets the execution state to finished after Alpha operations
    /// @dev Marks the end of a multi-action execution sequence
    ///
    /// Function behavior:
    /// - Resets execution state to 0
    /// - Marks completion of Alpha operations
    /// - Enables new execution sequences
    /// - Required for proper state management
    ///
    /// Called after:
    /// - Strategy execution completion
    /// - Market operation finalization
    /// - Protocol interaction completion
    /// - Multi-step transaction end
    ///
    /// Security considerations:
    /// - Must be called after executeStarted
    /// - Critical for execution state cleanup
    /// - Prevents execution state lock
    /// - Required for new operations
    ///
    /// @dev Important: State cleanup:
    /// - Enables new operations
    /// - Releases execution lock
    /// - Required for system stability
    /// - Prevents state corruption
    function executeFinished() internal {
        PlasmaVaultStorageLib.getExecutionState().value = 0;
    }

    /// @notice Checks if an Alpha execution sequence is currently active
    /// @return bool True if execution is in progress (state = 1), false otherwise
    /// @dev Verifies current execution state for operation validation
    ///
    /// State meanings:
    /// - True (1):
    ///   - Execution sequence active
    ///   - Alpha operation in progress
    ///   - Transaction sequence ongoing
    ///   - State modifications allowed
    ///
    /// - False (0):
    ///   - No active execution
    ///   - Ready for new operations
    ///   - Normal vault state
    ///   - Awaiting next sequence
    ///
    /// Used during:
    /// - Operation validation
    /// - State modification checks
    /// - Execution flow control
    /// - Error handling
    ///
    /// @dev Important considerations:
    /// - Critical for operation safety
    /// - Part of execution control flow
    /// - Affects state modification permissions
    /// - Used in reentrancy checks
    function isExecutionStarted() internal view returns (bool) {
        return PlasmaVaultStorageLib.getExecutionState().value == 1;
    }

    /// @notice Updates the Withdraw Manager address for the vault
    /// @param newWithdrawManager_ The new withdraw manager contract address
    /// @dev Updates withdraw manager configuration and emits event
    ///
    /// Configuration options:
    /// - Non-zero address: Enables scheduled withdrawals
    ///   - Enforces withdrawal schedules
    ///   - Manages withdrawal queues
    ///   - Handles withdrawal limits
    ///   - Coordinates withdrawal timing
    ///
    /// - Zero address: Disables scheduled withdrawals
    ///   - Turns off withdrawal scheduling
    ///   - Enables instant withdrawals only
    ///   - Bypasses withdrawal queues
    ///   - Removes withdrawal timing constraints
    ///
    /// Security considerations:
    /// - Only callable by authorized governance
    /// - Critical for withdrawal control
    /// - Affects user withdrawal options
    /// - Impacts liquidity management
    ///
    /// Integration impacts:
    /// - Withdrawal mechanisms
    /// - User withdrawal experience
    /// - Liquidity planning
    /// - Market stability
    ///
    /// @dev Important: Changes affect:
    /// - Withdrawal availability
    /// - Withdrawal timing
    /// - Liquidity management
    /// - User operations
    function updateWithdrawManager(address newWithdrawManager_) internal {
        PlasmaVaultStorageLib.getWithdrawManager().manager = newWithdrawManager_;
        emit WithdrawManagerChanged(newWithdrawManager_);
    }
}
