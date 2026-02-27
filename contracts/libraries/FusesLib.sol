// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";
import {FuseStorageLib} from "./FuseStorageLib.sol";
import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";
import {IporMath} from "./math/IporMath.sol";
/**
 * @title Fuses Library - Core Component for Plasma Vault's Fuse Management System
 * @notice Library managing the lifecycle and configuration of fuses - specialized contracts that enable
 * the Plasma Vault to interact with external DeFi protocols
 * @dev This library is a critical component that:
 * 1. Manages the addition and removal of fuses to the vault system
 * 2. Handles balance fuse associations with specific markets
 * 3. Provides validation and access functions for fuse operations
 * 4. Maintains the integrity of fuse-market relationships
 *
 * Key Components:
 * - Fuse Management: Adding/removing supported fuses
 * - Balance Fuse Control: Market-specific balance tracking
 * - Validation Functions: Fuse support verification
 * - Storage Integration: Uses FuseStorageLib for persistent storage
 *
 * Integration Points:
 * - Used by PlasmaVault.execute() to validate fuse operations
 * - Used by PlasmaVaultGovernance.sol for fuse configuration
 * - Interacts with FuseStorageLib for storage management
 * - Coordinates with PlasmaVaultStorageLib for market data
 *
 * Security Considerations:
 * - Enforces strict validation of fuse addresses
 * - Prevents duplicate fuse registrations
 * - Ensures proper market-fuse relationships
 * - Manages balance fuse removal conditions
 * - Critical for vault's protocol integration security
 *
 * @custom:security-contact security@ipor.io
 */
library FusesLib {
    using Address for address;

    event FuseAdded(address fuse);
    event FuseRemoved(address fuse);
    event BalanceFuseAdded(uint256 marketId, address fuse);
    event BalanceFuseRemoved(uint256 marketId, address fuse);

    error FuseAlreadyExists();
    error FuseDoesNotExist();
    error FuseUnsupported(address fuse);
    error BalanceFuseAlreadyExists(uint256 marketId, address fuse);
    error BalanceFuseDoesNotExist(uint256 marketId, address fuse);
    error BalanceFuseNotReadyToRemove(uint256 marketId, address fuse, uint256 currentBalance);
    error BalanceFuseMarketIdMismatch(uint256 marketId, address fuse);
    /**
     * @notice Validates if a fuse contract is registered and supported by the Plasma Vault
     * @dev Checks the FuseStorageLib mapping to verify fuse registration status
     * - A non-zero value in the mapping indicates the fuse is supported
     * - The value represents (index + 1) in the fusesArray
     * - Used by PlasmaVault.execute() to validate fuse operations
     * - Critical for security as it prevents unauthorized protocol integrations
     *
     * Integration Context:
     * - Called before any fuse operation in PlasmaVault.execute()
     * - Used by PlasmaVaultGovernance for fuse management
     * - Part of the vault's protocol integration security layer
     *
     * @param fuse_ The address of the fuse contract to check
     * @return bool Returns true if the fuse is supported, false otherwise
     *
     * Security Notes:
     * - Zero address returns false
     * - Only fuses added through governance can return true
     * - Non-existent fuses return false
     */
    function isFuseSupported(address fuse_) internal view returns (bool) {
        return FuseStorageLib.getFuses().value[fuse_] != 0;
    }

    /**
     * @notice Validates if a fuse is configured as the balance fuse for a specific market
     * @dev Checks the PlasmaVaultStorageLib mapping to verify balance fuse assignment
     * - Each market can have only one balance fuse at a time
     * - Balance fuses are responsible for tracking market-specific asset balances
     * - Used for market balance validation and updates
     *
     * Integration Context:
     * - Used during market balance updates in PlasmaVault._updateMarketsBalances()
     * - Referenced during balance fuse configuration in PlasmaVaultGovernance
     * - Critical for asset distribution protection system
     *
     * Market Balance System:
     * - Balance fuses track protocol-specific positions (e.g., Compound, Aave positions)
     * - Provides standardized balance reporting across different protocols
     * - Essential for maintaining accurate vault accounting
     *
     * @param marketId_ The unique identifier of the market to check
     * @param fuse_ The address of the balance fuse contract to verify
     * @return bool Returns true if the fuse is the designated balance fuse for the market
     *
     * Security Notes:
     * - Returns false for non-existent market-fuse pairs
     * - Only one balance fuse can be active per market
     * - Critical for preventing unauthorized balance reporting
     */
    function isBalanceFuseSupported(uint256 marketId_, address fuse_) internal view returns (bool) {
        return PlasmaVaultStorageLib.getBalanceFuses().fuseAddresses[marketId_] == fuse_;
    }

    /**
     * @notice Retrieves the designated balance fuse contract address for a specific market
     * @dev Provides direct access to the balance fuse mapping in PlasmaVaultStorageLib
     * - Returns zero address if no balance fuse is configured for the market
     * - Each market can have only one active balance fuse at a time
     *
     * Integration Context:
     * - Used by PlasmaVault._updateMarketsBalances() for balance tracking
     * - Called during market balance validation and updates
     * - Referenced by AssetDistributionProtectionLib for limit checks
     *
     * Use Cases:
     * - Balance calculation during vault operations
     * - Market position valuation
     * - Asset distribution protection checks
     * - Protocol-specific balance queries
     *
     * @param marketId_ The unique identifier of the market
     * @return address The address of the balance fuse contract for the market
     *         Returns address(0) if no balance fuse is configured
     *
     * Related Components:
     * - CompoundV3BalanceFuse
     * - AaveV3BalanceFuse
     * - Other protocol-specific balance fuses
     */
    function getBalanceFuse(uint256 marketId_) internal view returns (address) {
        return PlasmaVaultStorageLib.getBalanceFuses().fuseAddresses[marketId_];
    }

    /**
     * @notice Retrieves the complete array of supported fuse contracts in the Plasma Vault
     * @dev Provides direct access to the fuses array from FuseStorageLib
     * - Array order is NOT guaranteed to match insertion order; removeFuse uses swap-and-pop which reorders elements
     * - Used for fuse enumeration and management
     * - Critical for vault configuration and auditing
     *
     * Storage Pattern:
     * - Array indices correspond to (mapping value - 1) in FuseStorageLib.Fuses
     * - Maintains parallel structure with fuse mapping
     * - No duplicates allowed
     *
     * Integration Context:
     * - Used by PlasmaVaultGovernance for fuse management
     * - Referenced during vault configuration
     * - Used for fuse system auditing and verification
     * - Supports protocol integration management
     *
     * Use Cases:
     * - Fuse system configuration validation
     * - Protocol integration auditing
     * - Governance operations
     * - System state inspection
     *
     * @return address[] Array of all supported fuse contract addresses
     *
     * Related Functions:
     * - addFuse(): Appends to this array
     * - removeFuse(): Uses swap-and-pop; does NOT preserve array ordering
     * - getFuseArrayIndex(): Maps addresses to indices
     */
    function getFusesArray() internal view returns (address[] memory) {
        return FuseStorageLib.getFusesArray().value;
    }

    /**
     * @notice Retrieves the storage index for a given fuse contract
     * @dev Maps fuse addresses to their position in the fuses array
     * - Returns the value from FuseStorageLib.Fuses mapping
     * - Return value is (array index + 1) to distinguish from unsupported fuses
     * - Zero return value indicates fuse is not supported
     *
     * Storage Pattern:
     * - Mapping value = array index + 1
     * - Example: value 1 means index 0 in fusesArray
     * - Zero value means fuse not supported
     *
     * Integration Context:
     * - Used during fuse removal operations
     * - Supports array maintenance in removeFuse()
     * - Helps maintain storage consistency
     *
     * Use Cases:
     * - Fuse removal operations
     * - Storage validation
     * - Fuse support verification
     * - Array index lookups
     *
     * @param fuse_ The address of the fuse contract to look up
     * @return uint256 The storage index value (array index + 1) of the fuse
     *         Returns 0 if fuse is not supported
     *
     * Related Functions:
     * - addFuse(): Sets this index
     * - removeFuse(): Uses this for array maintenance
     * - getFusesArray(): Contains fuses at these indices
     */
    function getFuseArrayIndex(address fuse_) internal view returns (uint256) {
        return FuseStorageLib.getFuses().value[fuse_];
    }

    /**
     * @notice Registers a new fuse contract in the Plasma Vault's supported fuses list
     * @dev Manages the addition of fuses to both mapping and array storage
     * - Updates FuseStorageLib.Fuses mapping
     * - Appends to FuseStorageLib.FusesArray
     * - Maintains storage consistency between mapping and array
     *
     * Storage Updates:
     * 1. Checks for existing fuse to prevent duplicates
     * 2. Assigns new index (length + 1) in mapping
     * 3. Appends fuse address to array
     * 4. Emits FuseAdded event
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance.addFuses()
     * - Part of vault's protocol integration system
     * - Used during initial vault setup and protocol expansion
     *
     * Error Conditions:
     * - Reverts with FuseAlreadyExists if fuse is already registered
     * - Zero address handling done at governance level
     *
     * @param fuse_ The address of the fuse contract to add
     * @custom:events Emits FuseAdded when successful
     *
     * Security Considerations:
     * - Only callable through governance
     * - Critical for protocol integration security
     * - Must maintain storage consistency
     * - Affects vault's supported protocol list
     *
     * Gas Considerations:
     * - One SSTORE for mapping update
     * - One SSTORE for array push
     * - Event emission
     */
    function addFuse(address fuse_) internal {
        FuseStorageLib.Fuses storage fuses = FuseStorageLib.getFuses();

        uint256 keyIndexValue = fuses.value[fuse_];

        if (keyIndexValue != 0) {
            revert FuseAlreadyExists();
        }

        uint256 newLastFuseId = FuseStorageLib.getFusesArray().value.length + 1;

        /// @dev for balance fuses, value is a index + 1 in the fusesArray
        fuses.value[fuse_] = newLastFuseId;

        FuseStorageLib.getFusesArray().value.push(fuse_);

        emit FuseAdded(fuse_);
    }

    /**
     * @notice Removes a fuse contract from the Plasma Vault's supported fuses list
     * @dev Manages removal while maintaining storage consistency using swap-and-pop pattern
     * - Updates both FuseStorageLib.Fuses mapping and FusesArray
     * - Uses efficient swap-and-pop for array maintenance
     *
     * Storage Updates:
     * 1. Verifies fuse exists and gets its index
     * 2. Moves last array element to removed fuse's position
     * 3. Updates mapping for moved element
     * 4. Clears removed fuse's mapping entry
     * 5. Pops last array element
     * 6. Emits FuseRemoved event
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance.removeFuses()
     * - Part of protocol integration management
     * - Used during vault maintenance and protocol removal
     *
     * Error Conditions:
     * - Reverts with FuseDoesNotExist if fuse not found
     * - Zero address handling done at governance level
     *
     * @param fuse_ The address of the fuse contract to remove
     * @custom:events Emits FuseRemoved when successful
     *
     * Security Considerations:
     * - Only callable through governance
     * - Must maintain mapping-array consistency
     * - Critical for protocol integration security
     * - Affects vault's supported protocol list
     *
     * Gas Optimization:
     * - Uses swap-and-pop instead of shifting array
     * - Minimizes storage operations
     * - Three SSTORE operations:
     *   1. Update moved element's mapping
     *   2. Clear removed fuse's mapping
     *   3. Pop array
     */
    function removeFuse(address fuse_) internal {
        FuseStorageLib.Fuses storage fuses = FuseStorageLib.getFuses();

        uint256 indexToRemove = fuses.value[fuse_];

        if (indexToRemove == 0) {
            revert FuseDoesNotExist();
        }

        address lastKeyInArray = FuseStorageLib.getFusesArray().value[FuseStorageLib.getFusesArray().value.length - 1];

        fuses.value[lastKeyInArray] = indexToRemove;

        fuses.value[fuse_] = 0;

        /// @dev balanceFuses mapping contains values as index + 1
        FuseStorageLib.getFusesArray().value[indexToRemove - 1] = lastKeyInArray;

        FuseStorageLib.getFusesArray().value.pop();

        emit FuseRemoved(fuse_);
    }

    /**
     * @notice Associates a balance tracking fuse with a specific market in the Plasma Vault
     * @dev Manages market-specific balance fuse assignments and maintains market tracking data structures
     * - Updates both fuse mapping and market tracking arrays
     * - Maintains O(1) lookup capabilities through index mapping
     *
     * Storage Updates:
     * 1. Validates no duplicate fuse assignment
     * 2. Updates fuseAddresses mapping with new fuse
     * 3. Adds market to tracking array
     * 4. Updates index mapping for O(1) lookup
     * 5. Emits BalanceFuseAdded event
     *
     * Storage Pattern:
     * - balanceFuses.indexes[marketId_] stores (array index + 1)
     * - Example: value 1 means index 0 in marketIds array
     * - Matches pattern used in FuseStorageLib.Fuses mapping
     * - Allows distinguishing between non-existent (0) and first position (1)
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance.addBalanceFuse()
     * - Part of market setup and configuration
     * - Integrates with PlasmaVaultStorageLib.BalanceFuses
     * - Supports multi-market balance tracking system
     *
     * Market Tracking:
     * - Maintains ordered list of active markets
     * - Enables efficient market iteration
     * - Supports O(1) market existence checks
     * - Critical for balance update operations
     *
     * Error Conditions:
     * - Reverts with BalanceFuseAlreadyExists if:
     *   - Market already has this balance fuse
     *   - Prevents duplicate assignments
     *
     * @param marketId_ The unique identifier of the market
     * @param fuse_ The address of the balance fuse contract
     * @custom:events Emits BalanceFuseAdded when successful
     *
     * Security Considerations:
     * - Only callable through governance
     * - Must maintain array-mapping consistency
     * - Critical for market balance tracking
     * - Affects asset distribution protection
     * - Requires proper fuse validation
     *
     * Integration Points:
     * - PlasmaVault._updateMarketsBalances: Uses registered fuses
     * - AssetDistributionProtectionLib: Market balance checks
     * - Balance Fuses: Protocol-specific balance tracking
     * - Market Operations: Balance validation and updates
     */
    function addBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentFuse = PlasmaVaultStorageLib.getBalanceFuses().fuseAddresses[marketId_];

        if (currentFuse == fuse_) {
            revert BalanceFuseAlreadyExists(marketId_, fuse_);
        }

        if (marketId_ != IFuseCommon(fuse_).MARKET_ID()) {
            revert BalanceFuseMarketIdMismatch(marketId_, fuse_);
        }

        _updateBalanceFuseStructWhenAdding(marketId_, fuse_);

        emit BalanceFuseAdded(marketId_, fuse_);
    }

    /**
     * @notice Removes a balance tracking fuse from a specific market in the Plasma Vault
     * @dev Manages safe removal of market-fuse associations and updates market tracking data structures
     * - Uses swap-and-pop pattern for efficient array maintenance
     * - Maintains O(1) lookup capabilities through index mapping
     *
     * Storage Updates:
     * 1. Validates correct fuse-market association
     * 2. Verifies balance is below dust threshold via delegatecall
     * 3. Clears fuseAddresses mapping entry
     * 4. Updates marketIds array using swap-and-pop
     * 5. Updates indexes mapping for moved market
     * 6. Emits BalanceFuseRemoved event
     *
     * Storage Pattern:
     * - balanceFuses.indexes[marketId_] stores (array index + 1)
     * - Example: value 1 means index 0 in marketIds array
     * - Matches pattern used in FuseStorageLib.Fuses mapping
     * - Allows distinguishing between non-existent (0) and first position (1)
     *
     * Integration Context:
     * - Called by PlasmaVaultGovernance.removeBalanceFuse()
     * - Part of market decommissioning process
     * - Integrates with PlasmaVaultStorageLib.BalanceFuses
     * - Coordinates with balance fuse contracts
     *
     * Market Tracking:
     * - Maintains integrity of active markets list
     * - Updates market indexes after removal
     * - Preserves O(1) lookup capability
     * - Ensures proper market list maintenance
     *
     * Balance Validation:
     * - Uses delegatecall to check current balance
     * - Compares against dust threshold based on decimals
     * - Prevents removal of active positions
     * - Dust threshold scales with token precision
     *
     * Error Conditions:
     * - Reverts with BalanceFuseDoesNotExist if:
     *   - Fuse not assigned to market
     *   - Wrong fuse-market pair provided
     * - Reverts with BalanceFuseNotReadyToRemove if:
     *   - Balance exceeds dust threshold
     *   - Active positions exist
     *
     * @param marketId_ The unique identifier of the market
     * @param fuse_ The address of the balance fuse contract to remove
     * @custom:events Emits BalanceFuseRemoved when successful
     *
     * Security Considerations:
     * - Only callable through governance
     * - Must maintain array-mapping consistency
     * - Requires safe delegatecall handling
     * - Critical for market decommissioning
     * - Protects against premature removal
     *
     * Integration Points:
     * - PlasmaVault._updateMarketsBalances: Affected by removals
     * - Balance Fuses: Balance validation
     * - Asset Protection: Market tracking updates
     * - Market Operations: State consistency
     *
     * Gas Optimization:
     * - Uses swap-and-pop for array maintenance
     * - Minimizes storage operations
     * - Efficient market list updates
     * - Optimized for minimal gas usage
     */
    function removeBalanceFuse(uint256 marketId_, address fuse_) internal {
        address currentBalanceFuse = PlasmaVaultStorageLib.getBalanceFuses().fuseAddresses[marketId_];

        if (marketId_ != IFuseCommon(fuse_).MARKET_ID()) {
            revert BalanceFuseMarketIdMismatch(marketId_, fuse_);
        }

        if (currentBalanceFuse != fuse_) {
            revert BalanceFuseDoesNotExist(marketId_, fuse_);
        }

        uint256 wadBalanceAmountInUSD = abi.decode(
            currentBalanceFuse.functionDelegateCall(abi.encodeWithSignature("balanceOf()")),
            (uint256)
        );

        if (wadBalanceAmountInUSD > _calculateAllowedDustInBalanceFuse()) {
            revert BalanceFuseNotReadyToRemove(marketId_, fuse_, wadBalanceAmountInUSD);
        }

        _updateBalanceFuseStructWhenRemoving(marketId_);

        emit BalanceFuseRemoved(marketId_, fuse_);
    }

    /**
     * @notice Retrieves the list of all active markets with registered balance fuses
     * @dev Provides direct access to the ordered array of active market IDs from BalanceFuses storage
     * - Returns the complete marketIds array without modifications
     * - Order of markets matches their registration sequence
     *
     * Storage Access:
     * - Reads from PlasmaVaultStorageLib.BalanceFuses.marketIds
     * - No storage modifications
     * - O(1) operation for array access
     * - Returns reference to complete array
     *
     * Integration Context:
     * - Used by PlasmaVault._updateMarketsBalances for iteration
     * - Referenced during multi-market operations
     * - Supports balance update coordination
     * - Essential for market state management
     *
     * Use Cases:
     * - Market balance updates
     * - Asset distribution checks
     * - Market state validation
     * - Protocol-wide operations
     *
     * Array Properties:
     * - Maintained by addBalanceFuse/removeBalanceFuse
     * - No duplicates allowed
     * - Order may change during removals (swap-and-pop)
     * - Empty array possible if no active markets
     *
     * @return uint256[] Array of active market IDs with registered balance fuses
     *
     * Integration Points:
     * - Balance Update System: Market iteration
     * - Asset Protection: Market validation
     * - Governance: Market monitoring
     * - Protocol Operations: State checks
     *
     * Performance Notes:
     * - Returns a memory copy of the storage array (not a storage reference)
     * - Gas cost scales linearly with the number of active markets due to the copy
     * - Suitable for view function calls
     */
    function getActiveMarketsInBalanceFuses() internal view returns (uint256[] memory) {
        return PlasmaVaultStorageLib.getBalanceFuses().marketIds;
    }

    /// @dev Returns dust threshold in WAD (18 decimals) to match balanceOf() which returns USD in WAD
    /// IL-6962 fix: Balance fuses return values in WAD format, so dust threshold must also be in WAD
    function _calculateAllowedDustInBalanceFuse() private view returns (uint256) {
        uint8 underlyingDecimals = PlasmaVaultStorageLib.getERC4626Storage().underlyingDecimals;
        return IporMath.convertToWad(10 ** (underlyingDecimals / 2), underlyingDecimals);
    }

    function _updateBalanceFuseStructWhenAdding(uint256 marketId_, address fuse_) private {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();

        balanceFuses.fuseAddresses[marketId_] = fuse_;

        // @dev If marketId already has a fuse assigned, it's already in marketIds array,
        // @dev so skip adding it again to prevent duplicates. Only update the fuse address
        if (balanceFuses.indexes[marketId_] == 0) {
            uint256 newMarketIdIndexValue = balanceFuses.marketIds.length + 1;
            balanceFuses.marketIds.push(marketId_);
            balanceFuses.indexes[marketId_] = newMarketIdIndexValue;
        }
    }
    
    function _updateBalanceFuseStructWhenRemoving(uint256 marketId_) private {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();

        delete balanceFuses.fuseAddresses[marketId_];

        uint256 indexValue = balanceFuses.indexes[marketId_];
        uint256 marketIdsLength = balanceFuses.marketIds.length;

        if (indexValue != marketIdsLength) {
            balanceFuses.marketIds[indexValue - 1] = balanceFuses.marketIds[marketIdsLength - 1];
            balanceFuses.indexes[balanceFuses.marketIds[marketIdsLength - 1]] = indexValue;
        }
        balanceFuses.marketIds.pop();

        delete balanceFuses.indexes[marketId_];
    }
}
