// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library LiquityMath {
    uint256 internal constant DECIMAL_PRECISION = 1e18;
    uint256 internal constant MINUTES_IN_1000_YEARS = 525600000;

    function _min(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return (a_ < b_) ? a_ : b_;
    }

    function _max(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return (a_ >= b_) ? a_ : b_;
    }

    function _subMin0(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return (a_ > b_) ? a_ - b_ : 0;
    }

    /*
     * Multiply two decimal numbers and use normal rounding rules:
     * -round product up if 19'th mantissa digit >= 5
     * -round product down if 19'th mantissa digit < 5
     *
     * Used only inside the exponentiation, _decPow().
     */
    function decMul(uint256 x_, uint256 y_) internal pure returns (uint256 decProd) {
        uint256 prodXY = x_ * y_;

        decProd = (prodXY + DECIMAL_PRECISION / 2) / DECIMAL_PRECISION;
    }

    /*
     * _decPow: Exponentiation function for 18-digit decimal base, and integer exponent n.
     *
     * Uses the efficient "exponentiation by squaring" algorithm. O(log(n)) complexity.
     *
     * Called by function CollateralRegistry._calcDecayedBaseRate, that represent time in units of minutes
     *
     * The exponent is capped to avoid reverting due to overflow. The cap 525600000 equals
     * "minutes in 1000 years": 60 * 24 * 365 * 1000
     *
     * If a period of > 1000 years is ever used as an exponent in either of the above functions, the result will be
     * negligibly different from just passing the cap, since:
     *
     * In function 1), the decayed base rate will be 0 for 1000 years or > 1000 years
     * In function 2), the difference in tokens issued at 1000 years and any time > 1000 years, will be negligible
     */
    function _decPow(uint256 base_, uint256 minutes_) internal pure returns (uint256) {
        if (minutes_ > MINUTES_IN_1000_YEARS) minutes_ = MINUTES_IN_1000_YEARS; // cap to avoid overflow

        if (minutes_ == 0) return DECIMAL_PRECISION;

        uint256 y = DECIMAL_PRECISION;
        uint256 x = base_;
        uint256 n = minutes_;

        // Exponentiation-by-squaring
        while (n > 1) {
            if (n % 2 == 0) {
                x = decMul(x, x);
                n = n / 2;
            } else {
                // if (n % 2 != 0)
                y = decMul(x, y);
                x = decMul(x, x);
                n = (n - 1) / 2;
            }
        }

        return decMul(x, y);
    }

    function _getAbsoluteDifference(uint256 a_, uint256 b_) internal pure returns (uint256) {
        return (a_ >= b_) ? a_ - b_ : b_ - a_;
    }

    function _computeCR(uint256 coll_, uint256 debt_, uint256 price_) internal pure returns (uint256) {
        if (debt_ > 0) {
            uint256 newCollRatio = (coll_ * price_) / debt_;

            return newCollRatio;
        }
        // Return the maximal value for uint256 if the debt is 0. Represents "infinite" CR.
        else {
            // if (debt_ == 0)
            return 2 ** 256 - 1;
        }
    }
}