// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MarketValueSource
/// @notice Holds the USD-WAD value that `ExternalValueBalanceFuse` reports. The fuse runs by delegatecall in
///         the vault's storage context, so the value lives in this separate contract.
contract MarketValueSource {
    uint256 public value;

    function setValue(uint256 value_) external {
        value = value_;
    }
}

/// @title ExternalValueBalanceFuse
/// @notice Balance fuse for a non-crosschain market whose value the test sets directly. It stands in for any
///         other market of the vault (Aave, Morpho, ...) so a test can refresh that market on its own.
contract ExternalValueBalanceFuse {
    uint256 public immutable MARKET_ID;
    MarketValueSource public immutable SOURCE;

    constructor(uint256 marketId_, MarketValueSource source_) {
        MARKET_ID = marketId_;
        SOURCE = source_;
    }

    /// @notice Market value in 18-decimal USD, as set on `SOURCE`.
    function balanceOf() external view returns (uint256) {
        return SOURCE.value();
    }
}
