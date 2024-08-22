// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

/// @title Plasma Vault Configuration Library responsible for managing the configuration of the Plasma Vault
library PlasmaVaultConfigLib {
    event MarketSubstratesGranted(uint256 marketId, bytes32[] substrates);

    /// @notice Checks if the substrate treated as an asset is granted for the market
    /// @param marketId_ The market id
    /// @param substrateAsAsset The address of the substrate treated as an asset
    /// @return true if the substrate is granted for the market
    /// @dev Substrates are stored as bytes32
    function isSubstrateAsAssetGranted(uint256 marketId_, address substrateAsAsset) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);
        return marketSubstrates.substrateAllowances[addressToBytes32(substrateAsAsset)] == 1;
    }

    /// @notice Checks if the substrate is granted for the market
    /// @param marketId_ The market id
    /// @param substrate_ The bytes32 of the substrate
    /// @return true if the substrate is granted for the market
    /// @dev Substrates can be asset, vault, or any other params
    function isMarketSubstrateGranted(uint256 marketId_, bytes32 substrate_) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);
        return marketSubstrates.substrateAllowances[substrate_] == 1;
    }

    /// @notice Gets the market substrates for the market
    /// @param marketId_ The market id
    /// @return The array of substrates
    function getMarketSubstrates(uint256 marketId_) internal view returns (bytes32[] memory) {
        return _getMarketSubstrates(marketId_).substrates;
    }

    /// @notice Grants the substrates for the market
    /// @param marketId_ The market id
    /// @param substrates_ The array of substrates
    /// @dev Substrates can be asset, vault, or any other params, only granted substrates can be used by Fuses in interaction with a given market and external protocols.
    function grandMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);

        bytes32[] memory list = new bytes32[](substrates_.length);

        for (uint256 i; i < substrates_.length; ++i) {
            marketSubstrates.substrateAllowances[substrates_[i]] = 1;
            list[i] = substrates_[i];
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId_, substrates_);
    }

    /// @notice Grants the substrates treated as assets for the market
    /// @param marketId_ The market id
    /// @param substratesAsAssets_ The array of substrates treated as assets
    /// @dev Substrates are stored as bytes32, only granted substrates can be used by Fuses in interaction with a given market and external protocols.
    function grandSubstratesAsAssetsToMarket(uint256 marketId_, address[] calldata substratesAsAssets_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId_);

        bytes32[] memory list = new bytes32[](substratesAsAssets_.length);

        for (uint256 i; i < substratesAsAssets_.length; ++i) {
            marketSubstrates.substrateAllowances[addressToBytes32(substratesAsAssets_[i])] = 1;
            list[i] = addressToBytes32(substratesAsAssets_[i]);
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId_, list);
    }

    /// @notice Converts the substrate as bytes32 to value address
    /// @param substrate_ The bytes32 of the substrate
    /// @return The address of the substrate
    function bytes32ToAddress(bytes32 substrate_) internal pure returns (address) {
        return address(uint160(uint256(substrate_)));
    }

    /// @notice Converts the address to bytes32
    /// @param address_ The address of the substrate
    /// @return The bytes32 of the substrate
    function addressToBytes32(address address_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(address_)));
    }

    /// @notice Gets the market substrates configuration for a specific market
    function _getMarketSubstrates(
        uint256 marketId_
    ) private view returns (PlasmaVaultStorageLib.MarketSubstratesStruct storage) {
        return PlasmaVaultStorageLib.getMarketSubstrates().value[marketId_];
    }
}
