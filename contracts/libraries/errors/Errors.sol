// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Errors in Ipor Fusion
library Errors {
    /// @notice Error when wrong address is used
    error WrongAddress();
    /// @notice Error when wrong value is used
    error WrongValue();
    /// @notice Error when wrong decimals are used
    error WrongDecimals();
    /// @notice Error when wrong array length is used
    error WrongArrayLength();
    /// @notice Error when wrong caller is used
    error WrongCaller(address caller);
    /// @notice Error when wrong quote currency is used
    error UnsupportedQuoteCurrencyFromOracle();
    /// @notice Error when unsupported price oracle middleware is used
    error UnsupportedPriceOracleMiddleware();
}
