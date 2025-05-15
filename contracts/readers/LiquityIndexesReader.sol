// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";
import {FuseStorageLib} from "../libraries/FuseStorageLib.sol";

/**
 * @title LiquityIndexesReader
 * @notice Reader for LiquityV2OwnerIndexes data from PlasmaVault storage
 */
contract LiquityIndexesReader {
    function getLastIndex() external view returns (uint256) {
        return FuseStorageLib.getLiquityV2OwnerIndexes().lastIndex;
    }

    function getTroveId(address owner, uint256 ownerIndex) external view returns (uint256) {
        return FuseStorageLib.getLiquityV2OwnerIndexes().idByOwnerIndex[owner][ownerIndex];
    }

    function getLastIndex(address plasmaVault) external view returns (uint256 index) {
        ReadResult memory readResult = UniversalReader(plasmaVault).read(
            address(this),
            abi.encodeWithSignature("getLastIndex()")
        );
        index = abi.decode(readResult.data, (uint256));
    }

    function getTroveId(
        address plasmaVault,
        address owner,
        uint256 ownerIndex
    ) external view returns (uint256 troveId) {
        ReadResult memory readResult = UniversalReader(plasmaVault).read(
            address(this),
            abi.encodeWithSignature("getTroveId(address,uint256)", owner, ownerIndex)
        );
        troveId = abi.decode(readResult.data, (uint256));
    }
}
