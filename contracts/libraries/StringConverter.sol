// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

library StringConverter {
    // Optimized function - packs multiple characters into each bytes32
    function toBytes32(string memory s) internal pure returns (bytes32[] memory) {
        bytes memory b = bytes(s);
        uint256 charsPerBytes32 = 32; // Each bytes32 can hold 32 characters
        uint256 arrayLength = (b.length + charsPerBytes32 - 1) / charsPerBytes32; // Ceiling division
        bytes32[] memory result = new bytes32[](arrayLength);

        for (uint256 i; i < arrayLength; i++) {
            bytes32 packed = 0;
            uint256 startIndex = i * charsPerBytes32;
            uint256 endIndex = startIndex + charsPerBytes32;
            if (endIndex > b.length) {
                endIndex = b.length;
            }

            for (uint256 j = startIndex; j < endIndex; j++) {
                uint256 shift = (j - startIndex) * 8;
                packed |= bytes32(uint256(uint8(b[j])) << shift);
            }
            result[i] = packed;
        }
        return result;
    }

    // Optimized function - extracts multiple characters from each bytes32
    function fromBytes32(bytes32[] memory b) internal pure returns (string memory) {
        uint256 totalLength = 0;

        // Calculate total length (all bytes32 are full except possibly the last one)
        if (b.length > 0) {
            totalLength = (b.length - 1) * 32;
            // For the last bytes32, we need to count non-zero bytes
            bytes32 lastBytes32 = b[b.length - 1];
            for (uint256 i = 0; i < 32; i++) {
                uint8 byteValue = uint8(uint256(lastBytes32 >> (i * 8)));
                if (byteValue != 0) {
                    totalLength++;
                } else {
                    break;
                }
            }
        }

        bytes memory result = new bytes(totalLength);
        uint256 resultIndex = 0;

        for (uint256 i = 0; i < b.length; i++) {
            bytes32 currentBytes32 = b[i];

            for (uint256 j = 0; j < 32 && resultIndex < totalLength; j++) {
                uint8 byteValue = uint8(uint256(currentBytes32 >> (j * 8)));
                if (byteValue != 0) {
                    result[resultIndex] = bytes1(byteValue);
                    resultIndex++;
                } else {
                    break; // Stop at first null byte
                }
            }
        }

        return string(result);
    }
}
