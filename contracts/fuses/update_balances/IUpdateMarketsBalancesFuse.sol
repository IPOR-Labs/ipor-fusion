// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Data structure for entering UpdateMarketsBalancesFuse
/// @param marketIds Array of market IDs to update balances for
struct UpdateMarketsBalancesEnterData {
    uint256[] marketIds;
}

/// @title Interface for UpdateMarketsBalancesFuse events and errors
/// @author IPOR Labs
/// @notice Defines events and errors for the UpdateMarketsBalancesFuse contract
interface IUpdateMarketsBalancesFuse {
    /// @notice Emitted when markets balances are updated
    /// @param version The fuse version (deployment address)
    /// @param marketIds Array of market IDs that were updated
    event UpdateMarketsBalancesEnter(address indexed version, uint256[] marketIds);

    /// @notice Error thrown when exit() is called (not supported)
    error UpdateMarketsBalancesFuseExitNotSupported();

    /// @notice Error thrown when empty marketIds array is provided
    error UpdateMarketsBalancesFuseEmptyMarkets();
}
