// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Ipor Math library with math functions
library IporMath {
    uint256 private constant WAD_DECIMALS = 18;
    uint256 public constant BASIS_OF_POWER = 10;

    /// @dev The index of the most significant bit in a 256-bit signed integer
    uint256 private constant MSB = 255;

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    /// @notice Converts the value to WAD decimals, WAD decimals are 18
    /// @param value The value to convert
    /// @param assetDecimals The decimals of the asset
    /// @return The value in WAD decimals
    function convertToWad(uint256 value, uint256 assetDecimals) internal pure returns (uint256) {
        if (value > 0) {
            if (assetDecimals == WAD_DECIMALS) {
                return value;
            } else if (assetDecimals > WAD_DECIMALS) {
                return division(value, BASIS_OF_POWER ** (assetDecimals - WAD_DECIMALS));
            } else {
                return value * BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals);
            }
        } else {
            return value;
        }
    }

    /// @notice Converts the value to WAD decimals, WAD decimals are 18
    /// @param value The value to convert
    /// @param assetDecimals The decimals of the asset
    /// @return The value in WAD decimals
    function convertWadToAssetDecimals(uint256 value, uint256 assetDecimals) internal pure returns (uint256) {
        if (assetDecimals == WAD_DECIMALS) {
            return value;
        } else if (assetDecimals > WAD_DECIMALS) {
            return value * WAD_DECIMALS ** (assetDecimals - WAD_DECIMALS);
        } else {
            return division(value, BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals));
        }
    }

    /// @notice Converts the int value to WAD decimals, WAD decimals are 18
    /// @param value The int value to convert
    /// @param assetDecimals The decimals of the asset
    /// @return The value in WAD decimals, int
    function convertToWadInt(int256 value, uint256 assetDecimals) internal pure returns (int256) {
        if (value == 0) {
            return 0;
        }
        if (assetDecimals == WAD_DECIMALS) {
            return value;
        } else if (assetDecimals > WAD_DECIMALS) {
            return divisionInt(value, int256(BASIS_OF_POWER ** (assetDecimals - WAD_DECIMALS)));
        } else {
            return value * int256(BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals));
        }
    }

    /// @notice Divides two int256 numbers and rounds the result to the nearest integer
    /// @param x The numerator
    /// @param y The denominator
    /// @return z The result of the division
    function divisionInt(int256 x, int256 y) internal pure returns (int256 z) {
        uint256 absX = uint256(x < 0 ? -x : x);
        uint256 absY = uint256(y < 0 ? -y : y);

        // Use bitwise XOR to get the sign on MBS bit then shift to LSB
        // sign == 0x0000...0000 ==  0 if the number is non-negative
        // sign == 0xFFFF...FFFF == -1 if the number is negative
        int256 sign = (x ^ y) >> MSB;

        uint256 divAbs;
        uint256 remainder;

        unchecked {
            divAbs = absX / absY;
            remainder = absX % absY;
        }
        // Check if we need to round
        if (sign < 0) {
            // remainder << 1 left shift is equivalent to multiplying by 2
            if (remainder << 1 > absY) {
                ++divAbs;
            }
        } else {
            if (remainder << 1 >= absY) {
                ++divAbs;
            }
        }

        // (sign | 1) is cheaper than (sign < 0) ? -1 : 1;
        unchecked {
            z = int256(divAbs) * (sign | 1);
        }
    }

    /// @notice Divides two uint256 numbers and rounds the result to the nearest integer
    /// @param x The numerator
    /// @param y The denominator
    /// @return z The result of the division
    function division(uint256 x, uint256 y) internal pure returns (uint256 z) {
        z = x / y;
    }
}
