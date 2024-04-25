// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {CompoundV3BalanceFuse} from "../../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {PlazmaVaultStorageLib} from "../../../contracts/libraries/PlazmaVaultStorageLib.sol";
import {PlazmaVaultConfigLib} from "../../../contracts/libraries/PlazmaVaultConfigLib.sol";

contract CompoundV3BalanceFuseMock is CompoundV3BalanceFuse {
    constructor(
        uint256 marketIdInput,
        address cometAddressInput
    ) CompoundV3BalanceFuse(marketIdInput, cometAddressInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        PlazmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlazmaVaultStorageLib
            .getMarketSubstrates()
            .value[MARKET_ID];

        bytes32[] memory list = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketSubstrates.substrateAllowances[PlazmaVaultConfigLib.addressToBytes32(supportedAssets[i])] = 1;
            list[i] = PlazmaVaultConfigLib.addressToBytes32(supportedAssets[i]);
        }

        marketSubstrates.substrates = list;
    }
}
