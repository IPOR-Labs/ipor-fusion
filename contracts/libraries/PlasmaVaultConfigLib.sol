// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.24;

import {PlasmaVaultStorageLib} from "./PlasmaVaultStorageLib.sol";

library PlasmaVaultConfigLib {
    event MarketSubstratesGranted(uint256 marketId, bytes32[] substrates);

    function getMarketSubstrates(uint256 marketId) internal view returns (bytes32[] memory) {
        return _getMarketSubstrates(marketId).substrates;
    }

    function isSubstrateAsAssetGranted(uint256 marketId, address substrateAsAsset) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId);
        return marketSubstrates.substrateAllowances[addressToBytes32(substrateAsAsset)] == 1;
    }

    function isMarketSubstrateGranted(uint256 marketId, bytes32 substrate) internal view returns (bool) {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId);
        return marketSubstrates.substrateAllowances[substrate] == 1;
    }

    function grandMarketSubstrates(uint256 marketId, bytes32[] memory substrates) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId);

        bytes32[] memory list = new bytes32[](substrates.length);

        for (uint256 i; i < substrates.length; ++i) {
            marketSubstrates.substrateAllowances[substrates[i]] = 1;
            list[i] = substrates[i];
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId, substrates);
    }

    function grandSubstratesAsAssetsToMarket(uint256 marketId, address[] calldata substratesAsAssets) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = _getMarketSubstrates(marketId);

        bytes32[] memory list = new bytes32[](substratesAsAssets.length);

        for (uint256 i; i < substratesAsAssets.length; ++i) {
            marketSubstrates.substrateAllowances[addressToBytes32(substratesAsAssets[i])] = 1;
            list[i] = addressToBytes32(substratesAsAssets[i]);
        }

        marketSubstrates.substrates = list;

        emit MarketSubstratesGranted(marketId, list);
    }

    function bytes32ToAddress(bytes32 substrate) internal pure returns (address) {
        return address(uint160(uint256(substrate)));
    }

    function addressToBytes32(address addressInput) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addressInput)));
    }

    /// @notice Gets the market substrates configuration for a specific market
    function _getMarketSubstrates(
        uint256 marketId
    ) private view returns (PlasmaVaultStorageLib.MarketSubstratesStruct storage) {
        return PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
    }
}
