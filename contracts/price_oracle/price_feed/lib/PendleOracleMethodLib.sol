// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";

/// @title PendleOracleMethodLib
/// @notice Validates the Pendle oracle method used to price PT tokens
/// @dev PT prices are computed as rate * price of the asset from SY.assetInfo().
/// Method 0 (getPtToSyRate) returns the rate in SY units, so it is only correct when SY.exchangeRate() is 1:1
/// with that asset; for any other SY it misprices PT by the SY exchange rate. Method 1 (getPtToAssetRate)
/// returns the rate in asset units and is correct for every SY.
library PendleOracleMethodLib {
    /// @notice Oracle method pricing PT in SY units (getPtToSyRate)
    uint256 internal constant PT_TO_SY = 0;

    /// @notice Oracle method pricing PT in asset units (getPtToAssetRate)
    uint256 internal constant PT_TO_ASSET = 1;

    /// @notice Maximum deviation of SY.exchangeRate() from 1e18 accepted for PT_TO_SY (0.01%)
    uint256 internal constant MAX_SY_EXCHANGE_RATE_DEVIATION = 1e14;

    /// @notice Thrown when the oracle method is neither PT_TO_SY nor PT_TO_ASSET
    error InvalidPendleOracleMethod(uint256 method);

    /// @notice Thrown when PT_TO_SY is used with an SY whose exchange rate is not 1:1 with its asset
    error SyExchangeRateNotOne(uint256 exchangeRate);

    /// @notice Reverts when the oracle method is unknown or when PT_TO_SY is used with an SY that is not 1:1 with its asset
    /// @param sy_ The SY of the Pendle market
    /// @param method_ 0 for getPtToSyRate, 1 for getPtToAssetRate
    function validate(IStandardizedYield sy_, uint256 method_) internal view {
        if (method_ == PT_TO_ASSET) {
            return;
        }

        if (method_ != PT_TO_SY) {
            revert InvalidPendleOracleMethod(method_);
        }

        uint256 exchangeRate = sy_.exchangeRate();
        uint256 deviation = exchangeRate > 1e18 ? exchangeRate - 1e18 : 1e18 - exchangeRate;

        if (deviation > MAX_SY_EXCHANGE_RATE_DEVIATION) {
            revert SyExchangeRateNotOne(exchangeRate);
        }
    }
}
