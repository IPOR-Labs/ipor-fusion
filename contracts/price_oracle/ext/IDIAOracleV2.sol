// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IDIAOracleV2
/// @notice Minimal interface for DIA Data oracles (v2 API), used to read
/// asset prices published by DIA's key/value oracle contract.
/// @dev `timestamp` is the unix seconds of the last publication for the given
/// `key`. The number of decimals is commonly 8, but some chains publish with
/// 5 — callers configure the expected decimals per chain/key.
interface IDIAOracleV2 {
    /// @notice Returns the latest published value for `key`.
    /// @param key Human-readable pair identifier, e.g. "OUSD/USD".
    /// @return value Price in the oracle's native decimals (commonly 8).
    /// @return timestamp Unix seconds of the last publication.
    function getValue(string memory key) external view returns (uint128 value, uint128 timestamp);
}
