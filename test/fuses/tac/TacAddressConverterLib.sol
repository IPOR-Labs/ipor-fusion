// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;


/// @dev Don't use this library for production. It's only for testing purposes.
library TacAddressConverterLib {
    uint8 private constant BECH32_CHARSET_LENGTH = 32;
    uint8 private constant BECH32_SEPARATOR = 49; // '1'
    uint8 private constant BECH32_PREFIX_LENGTH = 3; // "tac"
    bytes private constant BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

    function stringToAddress(string memory addrStr) internal pure returns (address) {
        bytes memory addrBytes = bytes(addrStr);
        // Check if it's a TAC bech32 address (starts with "tac1")
        if (
            addrBytes.length >= 4 &&
            addrBytes[0] == "t" &&
            addrBytes[1] == "a" &&
            addrBytes[2] == "c" &&
            addrBytes[3] == "1"
        ) {
            bytes memory data = _decodeBech32(addrStr);
            return _bech32DataToAddress(data);
        }
        // If it's already a hex address (starts with "0x"), decode it normally
        if (addrBytes.length == 42 && addrBytes[0] == "0" && addrBytes[1] == "x") {
            uint256 result = 0;
            for (uint256 i = 2; i < 42; i++) {
                uint256 c = uint256(uint8(addrBytes[i]));
                uint256 d;
                if (c >= 0x30 && c <= 0x39) {
                    d = c - 0x30;
                } else if (c >= 0x61 && c <= 0x66) {
                    d = c - 0x61 + 10;
                } else if (c >= 0x41 && c <= 0x46) {
                    d = c - 0x41 + 10;
                } else {
                    revert("Invalid hex character");
                }
                result = result * 16 + d;
            }
            return address(uint160(result));
        }
        revert("Invalid address format");
    }

    function _decodeBech32(string memory bech32Addr) private pure returns (bytes memory data) {
        bytes memory addrBytes = bytes(bech32Addr);
        uint256 separatorPos = 0;
        for (uint256 i = 0; i < addrBytes.length; i++) {
            if (addrBytes[i] == bytes1(BECH32_SEPARATOR)) {
                separatorPos = i;
                break;
            }
        }
        require(separatorPos > 0, "Invalid bech32: no separator found");
        require(separatorPos >= BECH32_PREFIX_LENGTH, "Invalid bech32: prefix too short");
        bytes memory prefix = new bytes(separatorPos);
        for (uint256 i = 0; i < separatorPos; i++) {
            prefix[i] = addrBytes[i];
        }
        require(
            prefix.length == 3 && prefix[0] == "t" && prefix[1] == "a" && prefix[2] == "c",
            "Invalid bech32: wrong prefix"
        );
        uint256 dataLength = addrBytes.length - separatorPos - 1;
        require(dataLength > 0, "Invalid bech32: no data");
        data = _bech32ToBytes(addrBytes, separatorPos + 1);
        require(data.length >= 6, "Invalid bech32: data too short");
        bytes memory result = new bytes(data.length - 6);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i];
        }
        return result;
    }

    function _bech32ToBytes(bytes memory bech32Data, uint256 startPos) private pure returns (bytes memory) {
        uint256 dataLength = bech32Data.length - startPos;
        bytes memory result = new bytes(dataLength);
        for (uint256 i = 0; i < dataLength; i++) {
            uint8 c = uint8(bech32Data[startPos + i]);
            uint8 decoded = _bech32CharToValue(c);
            result[i] = bytes1(decoded);
        }
        return result;
    }

    function _bech32CharToValue(uint8 c) private pure returns (uint8) {
        if (c >= 0x61 && c <= 0x7a) {
            // a-z
            return c - 0x61;
        } else if (c >= 0x30 && c <= 0x39) {
            // 0-9
            return c - 0x30 + 26;
        } else {
            revert("Invalid bech32 character");
        }
    }

    function _bech32DataToAddress(bytes memory bech32Data) private pure returns (address) {
        require(bech32Data.length >= 20, "Invalid bech32 data length");
        uint256 addr = 0;
        for (uint256 i = 0; i < 20; i++) {
            addr = (addr << 8) | uint256(uint8(bech32Data[i]));
        }
        return address(uint160(addr));
    }
}
