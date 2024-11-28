// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {FusesLib} from "../libraries/FusesLib.sol";
import {IporFusionMarkets} from "../libraries/IporFusionMarkets.sol";
import {IFuseCommon} from "../fuses/IFuseCommon.sol";

/**
 * @title ReadBalanceFuses
 * @notice Contract to read balance fuses from PlasmaVault storage
 */
contract ReadBalanceFuses {
    /**
     * @notice Reads the balance fuse address for a specific market
     * @param marketId The ID of the market to query
     * @return The address of the balance fuse for the given market
     */
    function getBalanceFuse(uint256 marketId) external view returns (address) {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();
        return balanceFuses.value[marketId];
    }

    /**
     * @notice Reads all balance fuses for a list of market IDs
     * @return addresses Array of balance fuse addresses corresponding to the market IDs
     */
    function getBalanceFuses() external view returns (address[] memory addresses) {
        uint256[] memory marketIds = getMarketIds();
        uint256 marketIdsLength = marketIds.length;

        if (marketIds.length == 0) {
            return new address[](0);
        }

        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();
        addresses = new address[](marketIdsLength);

        for (uint256 i; i < marketIdsLength; i++) {
            addresses[i] = balanceFuses.value[marketIds[i]];
        }

        return addresses;
    }

    /**
     * @notice Gets all unique market IDs that have balance fuses assigned
     * @dev This function uses the DependencyBalanceGraph to find all markets
     * @return marketIds Array of unique market IDs
     */
    function getMarketIds() public view returns (uint256[] memory) {
        address[] memory fuses = FusesLib.getFusesArray();

        uint256 fusesLength = fuses.length;

        /// @dev +1 because of the ERC20_VAULT_BALANCE market
        uint256[] memory marketIds = new uint256[](fusesLength + 1);

        for (uint256 i; i < fusesLength; ++i) {
            marketIds[i] = IFuseCommon(fuses[i]).MARKET_ID();
        }
        marketIds[fusesLength] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256 uniqeMarkets = 0;
        uint256[] memory marketIdsUnique = new uint256[](fusesLength + 1);

        for (uint256 i; i < fusesLength + 1; ++i) {
            uint256 marketId = marketIds[i];
            if (!marketIdInArray(marketIdsUnique, marketId)) {
                marketIdsUnique[uniqeMarkets] = marketId;
                uniqeMarkets++;
            }
        }
        return reduceSizeOfArray(marketIdsUnique, uniqeMarkets);
    }

    function reduceSizeOfArray(uint256[] memory array, uint256 newSize) internal pure returns (uint256[] memory) {
        uint256[] memory newArray = new uint256[](newSize);
        for (uint256 i; i < newSize; ++i) {
            newArray[i] = array[i];
        }
        return newArray;
    }

    function marketIdInArray(uint256[] memory array, uint256 marketId) internal pure returns (bool) {
        for (uint256 i; i < array.length; ++i) {
            if (array[i] == marketId) {
                return true;
            }
        }
        return false;
    }
}
