// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;
import {ERC4626BalanceFuse} from "./../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {PlazmaVaultStorageLib} from "./../../../contracts/libraries/PlazmaVaultStorageLib.sol";
import {MarketConfigurationLib} from "./../../../contracts/libraries/MarketConfigurationLib.sol";

contract ERC4626BalanceFuseMock is ERC4626BalanceFuse {
    constructor(uint256 marketIdInput, address priceOracle) ERC4626BalanceFuse(marketIdInput, priceOracle) {}

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
