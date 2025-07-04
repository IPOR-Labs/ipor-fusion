// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {TacStakingStorageLib} from "../fuses/tac/TacStakingStorageLib.sol";
import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";

/**
 * @title TacStakingExecutorAddressReader
 * @notice Contract for reading TAC staking executor address from PlasmaVault
 * @dev Provides methods to access the TAC staking executor address both directly and through UniversalReader pattern
 */
contract TacStakingExecutorAddressReader {
    /**
     * @notice Reads the TAC staking executor address from storage
     * @return executorAddress The address of the TAC staking executor
     * @dev Returns the executor address stored in TacStakingStorageLib
     */
    function readTacStakingExecutorAddress() external view returns (address executorAddress) {
        executorAddress = TacStakingStorageLib.getTacStakingExecutor();
    }

    /**
     * @notice Reads TAC staking executor address from a specific PlasmaVault using UniversalReader
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @return executorAddress The address of the TAC staking executor
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     */
    function getTacStakingExecutorAddress(address plasmaVault_) external view returns (address executorAddress) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("readTacStakingExecutorAddress()")
        );
        executorAddress = abi.decode(readResult.data, (address));
    }
}
