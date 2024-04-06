// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import {AaveV3Balance} from "../../../contracts/connectors/aave_v3/AaveV3Balance.sol";
import {VaultStorageLib} from "../../../contracts/libraries/VaultStorageLib.sol";
import {MarketConfigurationLib} from "../../../contracts/libraries/MarketConfigurationLib.sol";

contract AaveV3BalanceMock is AaveV3Balance {
    constructor(uint256 marketIdInput) AaveV3Balance(marketIdInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        VaultStorageLib.MarketStruct storage marketConfig = MarketConfigurationLib.getMarketConfiguration(MARKET_ID);

        bytes32[] memory balanceSubstrates = new bytes32[](supportedAssets.length);

        for (uint256 i = 0; i < supportedAssets.length; i++) {
            marketConfig.substrateAllowances[MarketConfigurationLib.addressToBytes32(supportedAssets[i])] = 1;
            balanceSubstrates[i] = MarketConfigurationLib.addressToBytes32(supportedAssets[i]);
        }

        marketConfig.substrates = balanceSubstrates;
    }
}
