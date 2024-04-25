// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

import {AaveV2BalanceFuse} from "../../../contracts/fuses/aave_v2/AaveV2BalanceFuse.sol";
import {PlazmaVaultStorageLib} from "../../../contracts/libraries/PlazmaVaultStorageLib.sol";
import {PlazmaVaultConfigLib} from "../../../contracts/libraries/PlazmaVaultConfigLib.sol";

contract AaveV2BalanceFuseMock is AaveV2BalanceFuse {
    constructor(uint256 marketIdInput) AaveV2BalanceFuse(marketIdInput) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        PlazmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlazmaVaultStorageLib
            .getMarketSubstrates()
            .value[MARKET_ID];

        bytes32[] memory balanceSubstrates = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketSubstrates.substrateAllowances[PlazmaVaultConfigLib.addressToBytes32(supportedAssets[i])] = 1;
            balanceSubstrates[i] = PlazmaVaultConfigLib.addressToBytes32(supportedAssets[i]);
        }

        marketSubstrates.substrates = balanceSubstrates;
    }
}
