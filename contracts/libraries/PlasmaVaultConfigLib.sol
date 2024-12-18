// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

/// @title Plasma Vault Configuration Library responsible for managing the configuration of the Plasma Vault
library PlasmaVaultConfigLib {
    event MarketSubstratesGranted(uint256 marketId, bytes32[] substrates);

    /// @notice Checks if a given asset address is granted as a substrate for a specific market
    /// @dev This function is part of the Plasma Vault's substrate management system that controls which assets can be used in specific markets
    ///
    /// @param marketId_ The ID of the market to check
    /// @param substrateAsAsset The address of the asset to verify as a substrate
    /// @return bool True if the asset is granted as a substrate for the market, false otherwise
    ///
    /// @custom:security-notes
    /// - Substrates are stored internally as bytes32 values
    /// - Asset addresses are converted to bytes32 for storage efficiency
    /// - Part of the vault's asset distribution protection system
    ///
    /// @custom:context The function is used in conjunction with:
    /// - PlasmaVault's execute() function for validating market operations
    /// - PlasmaVaultGovernance's grantMarketSubstrates() for configuration
    /// - Asset distribution protection system for market limit enforcement
    ///
    /// @custom:example
    /// ```solidity
    /// // Check if USDC is granted for market 1
    /// bool isGranted = isSubstrateAsAssetGranted(1, USDC_ADDRESS);
    /// ```
    ///
    /// @custom:permissions
    /// - View function, no special permissions required
    /// - Substrate grants are managed by ATOMIST_ROLE through PlasmaVaultGovernance
    ///
    /// @custom:related-functions
    /// - grantMarketSubstrates(): For granting substrates to markets
    /// - isMarketSubstrateGranted(): For checking non-asset substrates
    /// - getMarketSubstrates(): For retrieving all granted substrates
    function isSubstrateAsAssetGranted(uint256 marketId_, address substrateAsAsset) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);
        return marketSubstrates.substrateAllowances[addressToBytes32(substrateAsAsset)] == 1;
    }

    /// @notice Validates if a substrate is granted for a specific market
    /// @dev Part of the Plasma Vault's substrate management system that enables flexible market configurations
    ///
    /// @param marketId_ The ID of the market to check
    /// @param substrate_ The bytes32 identifier of the substrate to verify
    /// @return bool True if the substrate is granted for the market, false otherwise
    ///
    /// @custom:security-notes
    /// - Substrates are stored and compared as raw bytes32 values
    /// - Used for both asset and non-asset substrates (e.g., vaults, parameters)
    /// - Critical for market access control and security
    ///
    /// @custom:context The function is used for:
    /// - Validating market operations in PlasmaVault.execute()
    /// - Checking substrate permissions before market interactions
    /// - Supporting various substrate types:
    ///   * Asset addresses (converted to bytes32)
    ///   * Protocol-specific vault identifiers
    ///   * Market parameters and configuration values
    ///
    /// @custom:example
    /// ```solidity
    /// // Check if a compound vault substrate is granted
    /// bytes32 vaultId = keccak256(abi.encode("compound-vault-1"));
    /// bool isGranted = isMarketSubstrateGranted(1, vaultId);
    ///
    /// // Check if a market parameter is granted
    /// bytes32 param = bytes32("max-leverage");
    /// bool isParamGranted = isMarketSubstrateGranted(1, param);
    /// ```
    ///
    /// @custom:permissions
    /// - View function, no special permissions required
    /// - Substrate grants are managed by ATOMIST_ROLE through PlasmaVaultGovernance
    ///
    /// @custom:related-functions
    /// - isSubstrateAsAssetGranted(): For checking asset-specific substrates
    /// - grantMarketSubstrates(): For granting substrates to markets
    /// - getMarketSubstrates(): For retrieving all granted substrates
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);
        return marketSubstrates.substrateAllowances[substrate_] == 1;
    }

    /// @notice Retrieves all granted substrates for a specific market
    /// @dev Part of the Plasma Vault's substrate management system that provides visibility into market configurations
    ///
    /// @param marketId_ The ID of the market to query
    /// @return bytes32[] Array of all granted substrate identifiers for the market
    ///
    /// @custom:security-notes
    /// - Returns raw bytes32 values that may represent different substrate types
    /// - Order of substrates in array is preserved from grant operations
    /// - Empty array indicates no substrates are granted
    ///
    /// @custom:context The function is used for:
    /// - Auditing market configurations
    /// - Validating substrate grants during governance operations
    /// - Supporting UI/external systems that need market configuration data
    /// - Debugging and monitoring market setups
    ///
    /// @custom:substrate-types The returned array may contain:
    /// - Asset addresses (converted to bytes32)
    /// - Protocol-specific vault identifiers
    /// - Market parameters and configuration values
    /// - Any other substrate type granted to the market
    ///
    /// @custom:example
    /// ```solidity
    /// // Get all substrates for market 1
    /// bytes32[] memory substrates = getMarketSubstrates(1);
    ///
    /// // Process different substrate types
    /// for (uint256 i = 0; i < substrates.length; i++) {
    ///     if (isSubstrateAsAssetGranted(1, bytes32ToAddress(substrates[i]))) {
    ///         // Handle asset substrate
    ///     } else {
    ///         // Handle other substrate type
    ///     }
    /// }
    /// ```
    ///
    /// @custom:permissions
    /// - View function, no special permissions required
    /// - Useful for both governance and user interfaces
    ///
    /// @custom:related-functions
    /// - isMarketSubstrateGranted(): For checking individual substrate grants
    /// - grantMarketSubstrates(): For modifying substrate grants
    /// - bytes32ToAddress(): For converting asset substrates back to addresses
    function getMarketSubstrates(uint256 marketId_) internal view returns (bytes32[] memory) {
        return _getMarketSubstrates(marketId_).substrates;
    }

    /// @notice Grants or updates substrate permissions for a specific market
    /// @dev Core function for managing market substrate configurations in the Plasma Vault system
    ///
    /// @param marketId_ The ID of the market to configure
    /// @param substrates_ Array of substrate identifiers to grant to the market
    ///
    /// @custom:security-notes
    /// - Revokes all existing substrate grants before applying new ones
    /// - Atomic operation - either all substrates are granted or none
    /// - Emits MarketSubstratesGranted event for tracking changes
    /// - Critical for market security and access control
    ///
    /// @custom:context The function is used for:
    /// - Initial market setup by governance
    /// - Updating market configurations
    /// - Managing protocol integrations
    /// - Controlling asset access per market
    ///
    /// @custom:substrate-handling
    /// - Accepts both asset and non-asset substrates:
    ///   * Asset addresses (converted to bytes32)
    ///   * Protocol-specific vault identifiers
    ///   * Market parameters
    ///   * Configuration values
    /// - Maintains a list of active substrates
    /// - Updates allowance mapping for each substrate
    ///
    /// @custom:example
    /// ```solidity
    /// // Grant multiple substrates to market 1
    /// bytes32[] memory substrates = new bytes32[](2);
    /// substrates[0] = addressToBytes32(USDC_ADDRESS);
    /// substrates[1] = keccak256(abi.encode("compound-vault-1"));
    /// grantMarketSubstrates(1, substrates);
    /// ```
    ///
    /// @custom:permissions
    /// - Should only be called by authorized governance functions
    /// - Typically restricted to ATOMIST_ROLE
    /// - Critical for vault security
    ///
    /// @custom:related-functions
    /// - isMarketSubstrateGranted(): For checking granted substrates
    /// - getMarketSubstrates(): For viewing current grants
    /// - grantSubstratesAsAssetsToMarket(): For asset-specific grants
    ///
    /// @custom:events
    /// - Emits MarketSubstratesGranted(marketId, substrates)
    function grantMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);

        _revokeMarketSubstrates(marketSubstrates);

        bytes32[] memory list = new bytes32[](substrates_.length);
        for (uint256 i; i < substrates_.length; ++i) {
            marketSubstrates.substrateAllowances[substrates_[i]] = 1;
            list[i] = substrates_[i];
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId_, substrates_);
    }

    /// @notice Grants asset-specific substrates to a market
    /// @dev Specialized function for managing asset-type substrates in the Plasma Vault system
    ///
    /// @param marketId_ The ID of the market to configure
    /// @param substratesAsAssets_ Array of asset addresses to grant as substrates
    ///
    /// @custom:security-notes
    /// - Revokes all existing substrate grants before applying new ones
    /// - Converts addresses to bytes32 for storage efficiency
    /// - Atomic operation - either all assets are granted or none
    /// - Emits MarketSubstratesGranted event with converted addresses
    /// - Critical for market asset access control
    ///
    /// @custom:context The function is used for:
    /// - Setting up asset permissions for markets
    /// - Managing DeFi protocol integrations
    /// - Controlling which tokens can be used in specific markets
    /// - Implementing asset-based strategies
    ///
    /// @custom:implementation-details
    /// - Converts each address to bytes32 using addressToBytes32()
    /// - Updates both allowance mapping and substrate list
    /// - Maintains consistency between address and bytes32 representations
    /// - Ensures proper event emission with converted values
    ///
    /// @custom:example
    /// ```solidity
    /// // Grant USDC and DAI access to market 1
    /// address[] memory assets = new address[](2);
    /// assets[0] = USDC_ADDRESS;
    /// assets[1] = DAI_ADDRESS;
    /// grantSubstratesAsAssetsToMarket(1, assets);
    /// ```
    ///
    /// @custom:permissions
    /// - Should only be called by authorized governance functions
    /// - Typically restricted to ATOMIST_ROLE
    /// - Critical for vault security and asset management
    ///
    /// @custom:related-functions
    /// - grantMarketSubstrates(): For granting general substrates
    /// - isSubstrateAsAssetGranted(): For checking asset grants
    /// - addressToBytes32(): For address conversion
    ///
    /// @custom:events
    /// - Emits MarketSubstratesGranted(marketId, convertedSubstrates)
    function grantSubstratesAsAssetsToMarket(uint256 marketId_, address[] calldata substratesAsAssets_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);

        _revokeMarketSubstrates(marketSubstrates);

        bytes32[] memory list = new bytes32[](substratesAsAssets_.length);

        for (uint256 i; i < substratesAsAssets_.length; ++i) {
            marketSubstrates.substrateAllowances[addressToBytes32(substratesAsAssets_[i])] = 1;
            list[i] = addressToBytes32(substratesAsAssets_[i]);
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId_, list);
    }

    /// @notice Converts an Ethereum address to its bytes32 representation for substrate storage
    /// @dev Core utility function for substrate address handling in the Plasma Vault system
    ///
    /// @param address_ The Ethereum address to convert
    /// @return bytes32 The bytes32 representation of the address
    ///
    /// @custom:security-notes
    /// - Performs unchecked conversion from address to bytes32
    /// - Pads the address (20 bytes) with zeros to fill bytes32 (32 bytes)
    /// - Used for storage efficiency in substrate mappings
    /// - Critical for consistent substrate identifier handling
    ///
    /// @custom:context The function is used for:
    /// - Converting asset addresses for substrate storage
    /// - Maintaining consistent substrate identifier format
    /// - Supporting the substrate allowance system
    /// - Enabling efficient storage and comparison operations
    ///
    /// @custom:implementation-details
    /// - Uses uint160 casting to handle address bytes
    /// - Follows standard Solidity type conversion patterns
    /// - Zero-pads the upper bytes implicitly
    /// - Maintains compatibility with bytes32ToAddress()
    ///
    /// @custom:example
    /// ```solidity
    /// // Convert USDC address to substrate identifier
    /// bytes32 usdcSubstrate = addressToBytes32(USDC_ADDRESS);
    ///
    /// // Use in substrate allowance mapping
    /// marketSubstrates.substrateAllowances[usdcSubstrate] = 1;
    /// ```
    ///
    /// @custom:permissions
    /// - Pure function, no state modifications
    /// - Can be called by any function
    /// - Used internally for substrate management
    ///
    /// @custom:related-functions
    /// - bytes32ToAddress(): Complementary conversion function
    /// - grantSubstratesAsAssetsToMarket(): Uses this for address conversion
    /// - isSubstrateAsAssetGranted(): Uses converted values for comparison
    function addressToBytes32(address address_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address_)));
    }

    /// @notice Converts a bytes32 substrate identifier to its corresponding address representation
    /// @dev Core utility function for substrate address handling in the Plasma Vault system
    ///
    /// @param substrate_ The bytes32 substrate identifier to convert
    /// @return address The resulting Ethereum address
    ///
    /// @custom:security-notes
    /// - Performs unchecked conversion from bytes32 to address
    /// - Only the last 20 bytes (160 bits) are used
    /// - Should only be used for known substrate conversions
    /// - Critical for proper asset substrate handling
    ///
    /// @custom:context The function is used for:
    /// - Converting stored substrate identifiers back to asset addresses
    /// - Processing asset-type substrates in market operations
    /// - Interfacing with external protocols using addresses
    /// - Validating asset substrate configurations
    ///
    /// @custom:implementation-details
    /// - Uses uint160 casting to ensure proper address size
    /// - Follows standard Solidity address conversion pattern
    /// - Maintains compatibility with addressToBytes32()
    /// - Zero-pads the upper bytes implicitly
    ///
    /// @custom:example
    /// ```solidity
    /// // Convert a stored substrate back to an asset address
    /// bytes32 storedSubstrate = marketSubstrates.substrates[0];
    /// address assetAddress = bytes32ToAddress(storedSubstrate);
    ///
    /// // Use in asset validation
    /// if (assetAddress == USDC_ADDRESS) {
    ///     // Handle USDC-specific logic
    /// }
    /// ```
    ///
    /// @custom:related-functions
    /// - addressToBytes32(): Complementary conversion function
    /// - isSubstrateAsAssetGranted(): Uses this for address comparison
    /// - getMarketSubstrates(): Returns values that may need conversion
    function bytes32ToAddress(bytes32 substrate_) internal pure returns (address) {
        return address(uint160(uint256(substrate_)));
    }

    /// @notice Gets the market substrates configuration for a specific market
    function _getMarketSubstrates(
        uint256 marketId_
    ) private view returns (PlasmaVaultStorageLib.MarketSubstratesStruct storage) {
        return PlasmaVaultStorageLib.getMarketSubstrates().value[marketId_];
    }

    function _revokeMarketSubstrates(PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates) private {
        uint256 length = marketSubstrates.substrates.length;
        for (uint256 i; i < length; ++i) {
            marketSubstrates.substrateAllowances[marketSubstrates.substrates[i]] = 0;
        }
    }
}
