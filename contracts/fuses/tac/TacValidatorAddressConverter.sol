// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

library TacValidatorAddressConverter {
    error TacValidatorAddressConverterInvalidAddress();

    /// @notice Converts a validator address string to two bytes32 values
    /// @param validatorAddress_ The validator address string to convert
    /// @return firstSlot_ First bytes32 value containing first part of string
    /// @return secondSlot_ Second bytes32 value containing second part of string
    function validatorAddressToBytes32(
        string memory validatorAddress_
    ) internal pure returns (bytes32 firstSlot_, bytes32 secondSlot_) {
        bytes memory strBytes = bytes(validatorAddress_);

        if (strBytes.length > 64) {
            revert TacValidatorAddressConverterInvalidAddress();
        }

        bytes memory paddedBytes = new bytes(64);

        for (uint256 i; i < strBytes.length; i++) {
            paddedBytes[i] = strBytes[i];
        }

        for (uint256 i = strBytes.length; i < 64; i++) {
            paddedBytes[i] = 0;
        }

        assembly {
            firstSlot_ := mload(add(paddedBytes, 32))
            secondSlot_ := mload(add(paddedBytes, 64))
        }
    }

    /// @notice Converts two bytes32 values back to a validator address string
    /// @param firstSlot_ First bytes32 value containing first part of string
    /// @param secondSlot_ Second bytes32 value containing second part of string
    /// @return The reconstructed validator address string
    function bytes32ToValidatorAddress(bytes32 firstSlot_, bytes32 secondSlot_) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(64);
        assembly {
            mstore(add(bytesArray, 32), firstSlot_)
            mstore(add(bytesArray, 64), secondSlot_)
        }
        /// @dev Find the real length (up to the first null byte)
        uint256 realLength = 64;
        for (uint256 i; i < 64; i++) {
            if (bytesArray[i] == 0) {
                realLength = i;
                break;
            }
        }
        bytes memory trimmed = new bytes(realLength);
        for (uint256 i; i < realLength; i++) {
            trimmed[i] = bytesArray[i];
        }
        return string(trimmed);
    }
}
