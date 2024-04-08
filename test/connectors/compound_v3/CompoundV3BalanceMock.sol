// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {CompoundV3Balance} from "../../../contracts/connectors/compound_v3/CompoundV3Balance.sol";
import {VaultStorageLib} from "../../../contracts/libraries/VaultStorageLib.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract CompoundV3BalanceMock is CompoundV3Balance {
    constructor(address cometAddressInput, uint256 marketIdInput) CompoundV3Balance(cometAddressInput, marketIdInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        VaultStorageLib.MarketStruct storage marketConfig = VaultStorageLib.getMarketConfiguration().value[MARKET_ID];

        bytes32[] memory balanceSubstrates = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketConfig.substrateAllowances[MarketConfigurationLib.addressToBytes32(supportedAssets[i])] = 1;
            balanceSubstrates[i] = MarketConfigurationLib.addressToBytes32(supportedAssets[i]);
        }

        marketConfig.substrates = balanceSubstrates;
    }
}
