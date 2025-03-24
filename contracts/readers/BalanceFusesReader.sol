// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultStorageLib} from "../libraries/PlasmaVaultStorageLib.sol";
import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";

/**
 * @title Balance Fuses Reader
 * @notice Contract for reading balance fuses data from PlasmaVault
 * @dev Provides methods to access market IDs and their corresponding fuse addresses
 */
contract BalanceFusesReader {
    /**
     * @notice Reads market IDs and their corresponding fuse addresses from storage
     * @return marketIds Array of market IDs
     * @return fuseAddresses Array of corresponding fuse addresses
     * @dev Returns parallel arrays where index i in marketIds_ corresponds to index i in fuseAddresses_
     */
    function readMarketIdsAndFuseAddressesForBalanceFuses()
        external
        view
        returns (uint256[] memory marketIds, address[] memory fuseAddresses)
    {
        PlasmaVaultStorageLib.BalanceFuses storage balanceFuses = PlasmaVaultStorageLib.getBalanceFuses();

        marketIds = balanceFuses.marketIds;
        uint256 length = marketIds.length;
        fuseAddresses = new address[](length);

        for (uint256 i; i < length; ++i) {
            fuseAddresses[i] = balanceFuses.fuseAddresses[marketIds[i]];
        }
    }

    /**
     * @notice Reads balance fuse information from a specific PlasmaVault using UniversalReader
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @return marketIds Array of market IDs from the vault
     * @return fuseAddresses Array of corresponding fuse addresses
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     */
    function getBalanceFuseInfo(
        address plasmaVault_
    ) external view returns (uint256[] memory marketIds, address[] memory fuseAddresses) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("readMarketIdsAndFuseAddressesForBalanceFuses()")
        );
        (marketIds, fuseAddresses) = abi.decode(readResult.data, (uint256[], address[]));
    }
}
