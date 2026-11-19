// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionMarkets} from "../../../libraries/IporFusionMarkets.sol";
import {HyperCorePendingLib} from "../../../fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreValuationLib} from "../../../fuses/hypercore/lib/HyperCoreValuationLib.sol";

/// @title HyperCoreCapitalFlowGatesLib
/// @notice Gates shared by every HyperCore capital-flow pre-hook (`HyperCoreCapitalFlowPreHook` and
///         `HyperCoreCapitalFlowFullRefreshPreHook`): everything a share-priced flow must pass before the vault
///         refreshes market 55 and prices shares (IL-9628).
/// @dev INVARIANT a capital-flow hook enforces, whatever its refresh scope (a Hooks V2 port, IL-9490, must keep it):
///      before any share-priced flow (deposit, depositWithPermit, mint, withdraw, redeem, redeemFromRequest) is priced,
///      1. a settled pending record is latched (`settleIfReady`),
///      2. no HyperCore transfer is pending (`requireNotPendingAction`),
///      3. no TIMING order sent in the current Core L1 block is unprocessed (`requireNoOrderInFlight`),
///      4. no held perp market's mark deviates from the Core oracle beyond the configured band
///         (`checkMarkOracleBand`),
///         held means a market with a granted `PerpMarket` substrate: after a grant is revoked while a position is
///         still open the band no longer covers that market (IL-9690, accepted: the atomist closes first, then revokes),
///      and only then market 55 (HYPERCORE) is refreshed, so Core positions, funding and fills are priced live.
///      The wrong-selector check (the hook must not run under `execute` / `updateMarketsBalances`) stays in each
///      hook, because its error is part of that hook's ABI.
///      Internal functions only: the code is inlined into the calling hook, which runs in the vault context.
library HyperCoreCapitalFlowGatesLib {
    /// @notice Runs gates 1-4 of the invariant above. Reverts with the HyperCore pending / order / band errors.
    function enforcePricingGates() internal {
        HyperCorePendingLib.settleIfReady();
        HyperCorePendingLib.requireNotPendingAction();
        HyperCorePendingLib.requireNoOrderInFlight();
        HyperCoreValuationLib.checkMarkOracleBand(IporFusionMarkets.HYPERCORE);
    }
}
