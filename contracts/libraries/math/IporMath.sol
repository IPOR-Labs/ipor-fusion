// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Ipor Math library with math functions
library IporMath {
    uint256 private constant WAD_DECIMALS = 18;
    uint256 public constant BASIS_OF_POWER = 10;

    /// @dev The index of the most significant bit in a 256-bit signed integer
    uint256 private constant MSB = 255;

    /// @notice Error when math operation would overflow
    error MathOverflow();

    function min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return a_ < b_ ? a_ : b_;
    }

    /// @notice Converts the value to WAD decimals, WAD decimals are 18
    /// @param value_ The value to convert
    /// @param assetDecimals_ The decimals of the asset
    /// @return The value in WAD decimals
    function convertToWad(uint256 value_, uint256 assetDecimals_) internal pure returns (uint256) {
        if (value_ > 0) {
            if (assetDecimals_ == WAD_DECIMALS) {
                return value_;
            } else if (assetDecimals_ > WAD_DECIMALS) {
                return division(value_, BASIS_OF_POWER ** (assetDecimals_ - WAD_DECIMALS));
            } else {
                return value_ * BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals_);
            }
        } else {
            return value_;
        }
    }

    /// @notice Converts the value to WAD decimals, WAD decimals are 18
    /// @param value_ The value to convert
    /// @param assetDecimals_ The decimals of the asset
    /// @return The value in WAD decimals
    function convertWadToAssetDecimals(uint256 value_, uint256 assetDecimals_) internal pure returns (uint256) {
        if (assetDecimals_ == WAD_DECIMALS) {
            return value_;
        } else if (assetDecimals_ > WAD_DECIMALS) {
            return value_ * BASIS_OF_POWER ** (assetDecimals_ - WAD_DECIMALS);
        } else {
            return division(value_, BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals_));
        }
    }

    /// @notice Converts the int value to WAD decimals, WAD decimals are 18
    /// @param value_ The int value to convert
    /// @param assetDecimals_ The decimals of the asset
    /// @return The value in WAD decimals, int
    /// @dev Reverts with MathOverflow if the result would overflow int256
    function convertToWadInt(int256 value_, uint256 assetDecimals_) internal pure returns (int256) {
        if (value_ == 0) {
            return 0;
        }
        if (assetDecimals_ == WAD_DECIMALS) {
            return value_;
        } else if (assetDecimals_ > WAD_DECIMALS) {
            return divisionInt(value_, int256(BASIS_OF_POWER ** (assetDecimals_ - WAD_DECIMALS)));
        } else {
            int256 scaleFactor = int256(BASIS_OF_POWER ** (WAD_DECIMALS - assetDecimals_));
            // Check for overflow before multiplication
            // |value_| * scaleFactor must not exceed type(int256).max
            // Handle type(int256).min special case - cannot safely negate
            if (value_ == type(int256).min) {
                revert MathOverflow();
            }
            int256 absValue = value_ < 0 ? -value_ : value_;
            if (absValue > type(int256).max / scaleFactor) {
                revert MathOverflow();
            }
            return value_ * scaleFactor;
        }
    }

    /// @notice Divides two int256 numbers and rounds the result to the nearest integer
    /// @param x_ The numerator
    /// @param y_ The denominator
    /// @return z The result of the division
    /// @dev Reverts with MathOverflow if x_ or y_ is type(int256).min (cannot negate)
    function divisionInt(int256 x_, int256 y_) internal pure returns (int256 z) {
        // Handle type(int256).min special case - cannot safely negate
        if (x_ == type(int256).min || y_ == type(int256).min) {
            revert MathOverflow();
        }

        uint256 absX_ = uint256(x_ < 0 ? -x_ : x_);
        uint256 absY_ = uint256(y_ < 0 ? -y_ : y_);

        // Use bitwise XOR to get the sign on MBS bit then shift to LSB
        // sign == 0x0000...0000 ==  0 if the number is non-negative
        // sign == 0xFFFF...FFFF == -1 if the number is negative
        int256 sign = (x_ ^ y_) >> MSB;

        uint256 divAbs;
        uint256 remainder;

        unchecked {
            divAbs = absX_ / absY_;
            remainder = absX_ % absY_;
        }
        // Check if we need to round
        if (sign < 0) {
            // remainder << 1 left shift is equivalent to multiplying by 2
            if (remainder << 1 > absY_) {
                ++divAbs;
            }
        } else {
            if (remainder << 1 >= absY_) {
                ++divAbs;
            }
        }

        // (sign | 1) is cheaper than (sign < 0) ? -1 : 1;
        unchecked {
            z = int256(divAbs) * (sign | 1);
        }
    }

    /// @notice Divides two uint256 numbers and rounds the result to the nearest integer
    /// @param x_ The numerator
    /// @param y_ The denominator
    /// @return z_ The result of the division
    function division(uint256 x_, uint256 y_) internal pure returns (uint256 z_) {
        z_ = x_ / y_;
    }
}
