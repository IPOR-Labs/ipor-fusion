// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.22;

import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract AaveV3BalanceFuseMock is AaveV3BalanceFuse {
    constructor(
        uint256 marketIdInput,
        address aavePriceOracle,
        address aavePoolDataProviderV3
    ) AaveV3BalanceFuse(marketIdInput, aavePriceOracle, aavePoolDataProviderV3) {}

    function updateMarketConfiguration(address[] memory supportedAssets) public {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlasmaVaultStorageLib
            .getMarketSubstrates()
            .value[MARKET_ID];

        bytes32[] memory list = new bytes32[](supportedAssets.length);

        for (uint256 i; i < supportedAssets.length; ++i) {
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i])] = 1;
            list[i] = PlasmaVaultConfigLib.addressToBytes32(supportedAssets[i]);
        }

        marketSubstrates.substrates = list;
    }
}
