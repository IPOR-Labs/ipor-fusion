// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UniversalReader, ReadResult} from "../universal_reader/UniversalReader.sol";
import {WethEthAdapterStorageLib} from "../fuses/ebisu/lib/WethEthAdapterStorageLib.sol";
import {TacValidatorAddressConverter} from "../fuses/tac/lib/TacValidatorAddressConverter.sol";

/**
 * @title EbisuWethEthAdapterAddressReader
 * @notice Contract for reading Ebisu WethEthAdapter address from PlasmaVault
 * @dev Provides methods to access the Ebisu WethEthAdapter address both directly and through UniversalReader pattern
 * @dev Reuse TacValidatorAddressConverter since it does not refer in any way specifically to TAC
 */
contract EbisuWethEthAdapterAddressReader {
    /**
     * @notice Reads the Ebisu WethEthAdapter address from storage
     * @return adapterAddress The address of the Ebisu WethEthAdapter
     * @dev Returns the delegator address stored in WethEthAdapterStorageLib
     */
    function readEbisuWethEthAdapterAddress() external view returns (address adapterAddress) {
        adapterAddress = WethEthAdapterStorageLib.getWethEthAdapter();
    }

    /**
     * @notice Reads Ebisu WethEthAdapter address from a specific PlasmaVault using UniversalReader
     * @param plasmaVault_ Address of the PlasmaVault to read from
     * @return adapterAddress The address of the Ebisu WethEthAdapter delegator
     * @dev Uses UniversalReader pattern to safely read data from the target vault
     */
    function getEbisuWethEthAdapterAddress(address plasmaVault_) external view returns (address adapterAddress) {
        ReadResult memory readResult = UniversalReader(address(plasmaVault_)).read(
            address(this),
            abi.encodeWithSignature("readEbisuWethEthAdapterAddress()")
        );
        adapterAddress = abi.decode(readResult.data, (address));
    }

    /// @notice Converts a adapter address string (Bech32) to two bytes32 values
    /// @param adapteraddress_ The adapter address string to convert
    /// @return firstSlot_ First bytes32 value containing first part of string
    /// @return secondSlot_ Second bytes32 value containing second part of string
    function convertAdapetrAddressToBytes32(string memory adapteraddress_) external pure returns (bytes32, bytes32) {
        return TacValidatorAddressConverter.validatorAddressToBytes32(adapteraddress_);
    }

    /// @notice Converts two bytes32 values back to a adapter address string (Bech32)
    /// @param firstSlot_ First bytes32 value containing first part of string
    /// @param secondSlot_ Second bytes32 value containing second part of string
    /// @return The reconstructed adapter address string (Bech32)
    function convertBytes32ToAdapterAddress(
        bytes32 firstSlot_,
        bytes32 secondSlot_
    ) external pure returns (string memory) {
        return TacValidatorAddressConverter.bytes32ToValidatorAddress(firstSlot_, secondSlot_);
    }
}
