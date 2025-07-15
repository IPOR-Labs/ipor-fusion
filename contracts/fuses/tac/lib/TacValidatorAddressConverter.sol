// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library TacValidatorAddressConverter {
    error TacValidatorAddressConverterInvalidAddress();

    /// @notice Converts a validator address string to two bytes32 values
    /// @param validatorAddress_ The validator address string to convert
    /// @return firstSlot_ First bytes32 value containing length and first part of string
    /// @return secondSlot_ Second bytes32 value containing second part of string
    /// @dev Notice! firstSlot_ contains the length of the string in the first byte
    function validatorAddressToBytes32(
        string memory validatorAddress_
    ) internal pure returns (bytes32 firstSlot_, bytes32 secondSlot_) {
        bytes memory strBytes = bytes(validatorAddress_);

        uint256 strBytesLength = strBytes.length;

        if (strBytesLength > 63) {
            revert TacValidatorAddressConverterInvalidAddress();
        }

        bytes memory paddedBytes = new bytes(64);

        paddedBytes[0] = bytes1(uint8(strBytesLength));

        for (uint256 i; i < strBytesLength; i++) {
            paddedBytes[i + 1] = strBytes[i];
        }

        for (uint256 i = strBytesLength + 1; i < 64; i++) {
            paddedBytes[i] = 0;
        }

        assembly {
            firstSlot_ := mload(add(paddedBytes, 32))
            secondSlot_ := mload(add(paddedBytes, 64))
        }
    }

    /// @notice Converts two bytes32 values back to a validator address string
    /// @param firstSlot_ First bytes32 value containing length and first part of string
    /// @param secondSlot_ Second bytes32 value containing second part of string
    /// @return The reconstructed validator address string
    /// @dev Notice! firstSlot_ contains the length of the string in the first byte
    function bytes32ToValidatorAddress(bytes32 firstSlot_, bytes32 secondSlot_) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(64);
        assembly {
            mstore(add(bytesArray, 32), firstSlot_)
            mstore(add(bytesArray, 64), secondSlot_)
        }

        uint256 originalLength = uint8(bytesArray[0]);

        bytes memory result = new bytes(originalLength);

        for (uint256 i; i < originalLength; i++) {
            result[i] = bytesArray[i + 1];
        }

        return string(result);
    }
}
