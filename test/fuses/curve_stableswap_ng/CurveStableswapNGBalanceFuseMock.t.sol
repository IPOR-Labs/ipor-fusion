// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {CurveStableswapNGBalanceFuse} from "./../../../contracts/fuses/curve_stableswap_ng/CurveStableswapNGBalanceFuse.sol";
import {PlasmaVaultStorageLib} from "./../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "./../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract CurveStableswapNGBalanceFuseMock is CurveStableswapNGBalanceFuse {
    constructor(
        uint256 marketIdInput,
        address curveStableswapNGPriceOracle
    ) CurveStableswapNGBalanceFuse(marketIdInput, curveStableswapNGPriceOracle) {}

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
