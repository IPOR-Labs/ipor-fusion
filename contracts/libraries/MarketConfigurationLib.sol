// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {VaultStorageLib} from "./VaultStorageLib.sol";

library MarketConfigurationLib {
    /// @notice Gets the market configuration for a specific market
    function getMarketConfiguration(uint256 marketId) internal view returns (VaultStorageLib.MarketStruct storage) {
        return VaultStorageLib.getMarketConfiguration().value[marketId];
    }

    function isSubstrateAsAssetGranted(uint256 marketId, address substrateAsAsset) internal view returns (bool) {
        VaultStorageLib.MarketStruct storage marketConfiguration = getMarketConfiguration(marketId);
        return marketConfiguration.substrateAllowances[addressToBytes32(substrateAsAsset)] == 1;
    }

    function grandSubstratesToMarket(uint256 marketId, bytes32[] memory substrates) internal {
        VaultStorageLib.MarketStruct storage marketConfig = getMarketConfiguration(marketId);

        bytes32[] memory balanceSubstrates = new bytes32[](substrates.length);

        for (uint256 i = 0; i < substrates.length; i++) {
            marketConfig.substrateAllowances[substrates[i]] = 1;
            balanceSubstrates[i] = substrates[i];
        }

        marketConfig.substrates = balanceSubstrates;
    }

    function grandSubstratesAsAssetsToMarket(uint256 marketId, address[] calldata substratesAsAssets) internal {
        VaultStorageLib.MarketStruct storage marketConfig = getMarketConfiguration(marketId);

        bytes32[] memory balanceSubstrates = new bytes32[](substratesAsAssets.length);

        for (uint256 i = 0; i < substratesAsAssets.length; i++) {
            marketConfig.substrateAllowances[addressToBytes32(substratesAsAssets[i])] = 1;
            balanceSubstrates[i] = addressToBytes32(substratesAsAssets[i]);
        }

        marketConfig.substrates = balanceSubstrates;
    }

    function bytes32ToAddress(bytes32 substrate) internal pure returns (address) {
        return address(uint160(uint256(substrate)));
    }

    function addressToBytes32(address addressInput) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addressInput)));
    }
}
