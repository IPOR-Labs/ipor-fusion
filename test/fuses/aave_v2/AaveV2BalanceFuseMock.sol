// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {AaveV2BalanceFuse} from "../../../contracts/fuses/aave_v2/AaveV2BalanceFuse.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract AaveV2BalanceFuseMock is AaveV2BalanceFuse {
    constructor(uint256 marketIdInput) AaveV2BalanceFuse(marketIdInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlasmaVaultStorageLib
            .getMarketSubstrates()
            .value[MARKET_ID];

        bytes32[] memory balanceSubstrates = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i])] = 1;
            balanceSubstrates[i] = PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i]);
        }

        marketSubstrates.substrates = balanceSubstrates;
    }
}
