// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.24;
import {ERC4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlasmaVaultStorageLib} from "./../../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "./../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract ERC4626BalanceFuseMock is ERC4626BalanceFuse {
    constructor(uint256 marketIdInput, address priceOracle) ERC4626BalanceFuse(marketIdInput, priceOracle) {}

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
