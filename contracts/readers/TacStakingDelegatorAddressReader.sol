// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";
import {TacStakingStorageLib} from "../fuses/tac/lib/TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "../fuses/tac/lib/TacValidatorAddressConverter.sol";

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

    /// @notice Converts a validator address string (Bech32) to two bytes32 values
    /// @param validatorAddress_ The validator address string to convert
    /// @return firstSlot_ First bytes32 value containing first part of string
    /// @return secondSlot_ Second bytes32 value containing second part of string
    function convertValidatorAddressToBytes32(
        string memory validatorAddress_
    ) external pure returns (bytes32, bytes32) {
        return TacValidatorAddressConverter.validatorAddressToBytes32(validatorAddress_);
    }

    /// @notice Converts two bytes32 values back to a validator address string (Bech32)
    /// @param firstSlot_ First bytes32 value containing first part of string
    /// @param secondSlot_ Second bytes32 value containing second part of string
    /// @return The reconstructed validator address string (Bech32)
    function convertBytes32ToValidatorAddress(
        bytes32 firstSlot_,
        bytes32 secondSlot_
    ) external pure returns (string memory) {
        return TacValidatorAddressConverter.bytes32ToValidatorAddress(firstSlot_, secondSlot_);
    }
}
