// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TacStakingStorageLib} from "../fuses/tac/TacStakingStorageLib.sol";
import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";

/**
 * @title TacStakingDelegatorAddressReader
 * @notice Contract for reading TAC staking delegator address from PlasmaVault
 * @dev Provides methods to access the TAC staking delegator address both directly and through UniversalReader pattern
 */
contract TacStakingDelegatorAddressReader {
    /**
     * @notice Reads the TAC staking delegator address from storage
     * @return delegatorAddress The address of the TAC staking delegator
     * @dev Returns the delegator address stored in TacStakingStorageLib
     */
    function readTacStakingDelegatorAddress() external view returns (address delegatorAddress) {
        delegatorAddress = TacStakingStorageLib.getTacStakingDelegator();
    }

    /**
     * @notice Reads TAC staking delegator address from a specific PlasmaVault using UniversalReader
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @return delegatorAddress The address of the TAC staking delegator
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     */
    function getTacStakingDelegatorAddress(address plasmaVault_) external view returns (address delegatorAddress) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("readTacStakingDelegatorAddress()")
        );
        delegatorAddress = abi.decode(readResult.data, (address));
    }
}
