// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {AaveV2BalanceFuse} from "../../../contracts/fuses/aave_v2/AaveV2BalanceFuse.sol";
import {PlazmaVaultStorageLib} from "../../../contracts/libraries/PlazmaVaultStorageLib.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract AaveV2BalanceFuseMock is AaveV2BalanceFuse {
    constructor(uint256 marketIdInput) AaveV2BalanceFuse(marketIdInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        PlazmaVaultStorageLib.MarketStruct storage marketConfig = PlazmaVaultStorageLib.getMarketConfiguration().value[
            MARKET_ID
        ];

        bytes32[] memory balanceSubstrates = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketConfig.substrateAllowances[MarketConfigurationLib.addressToBytes32(supportedAssets[i])] = 1;
            balanceSubstrates[i] = MarketConfigurationLib.addressToBytes32(supportedAssets[i]);
        }

        marketConfig.substrates = balanceSubstrates;
    }
}
