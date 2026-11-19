// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Data structure for entering UpdateMarketsBalancesFuse
/// @param marketIds Array of market IDs to update balances for; the markets are refreshed and then recorded, so the
///        vault re-reads and limit-checks them again at the end of the current execute (IL-9708)
struct UpdateMarketsBalancesEnterData {
    uint256[] marketIds;
}

/// @title Interface for UpdateMarketsBalancesFuse events and errors
/// @author IPOR Labs
/// @notice Defines events and errors for the UpdateMarketsBalancesFuse contract
interface IUpdateMarketsBalancesFuse {
    /// @notice Emitted when markets balances are updated (and recorded for the final re-read of execute)
    /// @param version The fuse version (deployment address)
    /// @param marketIds Array of market IDs that were updated
    event UpdateMarketsBalancesEnter(address indexed version, uint256[] marketIds);

    /// @notice Error thrown when exit() is called (not supported)
    error UpdateMarketsBalancesFuseExitNotSupported();

    /// @notice Error thrown when empty marketIds array is provided
    error UpdateMarketsBalancesFuseEmptyMarkets();
}
