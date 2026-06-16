// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @notice Single action executed by the RWA executor.
/// @param target Target contract address (external protocol, router, etc.).
/// @param data ABI-encoded calldata forwarded to `target` via `Address.functionCall`.
struct RWAExecutorAction {
    address target;
    bytes data;
}

/// @title IRWAExecutor
/// @notice Interface of the per-vault RWAExecutor contract. Mirrors the public surface used by
///         `RWAOperationFuse`, `RWABalanceFuse`, `RWAPausePreHook`, `RWAUnpauseFuse`, and `RWARescueFuse`.
/// @dev The executor is NOT a fuse — it is deployed once per vault (per market) and holds funds.
/// @author IPOR Labs
interface IRWAExecutor {
    // ============================================================
    // Vault-gated write path
    // ============================================================

    /// @notice Increment the tracked balance of a balance account.
    /// @dev Called by the operation fuse on enter. The balance fuse does not call `addBalance`;
    ///      only the operation fuse does. No balance-account validation here —
    ///      `RWAOperationFuse._validateSubstratesAndActions` validates BA against vault substrates
    ///      before this call. The orphaned-balance invariant is enforced at the `syncSubstrates()`
    ///      boundary — see `syncSubstrates` invariant docs and the
    ///      `RWAExecutorBalanceAccountStillFunded` error in `errors/RWAErrors.sol`.
    /// @param balanceAccount_ The balance account receiving the deposit.
    /// @param valueInUnderlying_ The amount in vault underlying units.
    function addBalance(address balanceAccount_, uint256 valueInUnderlying_) external;

    /// @notice Decrement the tracked balance of a balance account and transfer `tokenAmount_` of `asset_` to the vault.
    /// @param balanceAccount_ The balance account being decremented.
    /// @param valueInUnderlying_ The amount in vault underlying units to remove from the tracked balance.
    /// @param asset_ The asset token to transfer back to the vault.
    /// @param tokenAmount_ Amount of `asset_` (in asset decimals) to transfer back.
    function removeBalance(address balanceAccount_, uint256 valueInUnderlying_, address asset_, uint256 tokenAmount_)
        external;

    /// @notice Execute a batch of external calls from the executor context.
    /// @param actions_ Ordered list of (target, data) tuples forwarded via `Address.functionCall`.
    function execute(RWAExecutorAction[] calldata actions_) external;

    /// @notice Withdraw the entire executor balance of `asset_` to the vault without touching tracked balances.
    /// @param asset_ Asset token whose executor balance should be swept to the vault.
    function withdrawAssetBalance(address asset_) external;

    // ============================================================
    // Custodian dual-approval balance updates
    // ============================================================

    /// @notice Propose a new total balance for `balanceAccount_`. Requires custodian role.
    /// @dev Reverts with `RWAUnsupportedSubstrate(BALANCE_ACCOUNT, _)` if `balanceAccount_` is
    ///      not currently granted in the vault substrate set. This check uses **vault substrates**
    ///      (source of truth via `IPlasmaVaultGovernance.isMarketSubstrateGranted`), not the
    ///      executor cache — closing the race window between `revokeMarketSubstrates(...)` and
    ///      `syncSubstrates()`.
    /// @param balanceAccount_ The balance account receiving the proposed update.
    /// @param newValue_ Proposed new total balance in vault underlying units.
    function proposeBalance(address balanceAccount_, uint256 newValue_) external;

    /// @notice Confirm a previously proposed balance. Requires a *different* custodian than the proposer.
    /// @dev Reverts with `RWAUnsupportedSubstrate(BALANCE_ACCOUNT, _)` if `balanceAccount_` is
    ///      not currently granted in the vault substrate set. The check is applied as the very
    ///      first step (authorization-first) before any pending-proposal, hash, TTL, dust, or
    ///      min-update-interval validation.
    /// @param balanceAccount_ The balance account whose pending proposal is being confirmed.
    /// @param proposalHash_ Hash of `(value, proposer, proposedAt, nonce)` as returned by `proposeBalance`.
    function confirmBalance(address balanceAccount_, bytes32 proposalHash_) external;

    // ============================================================
    // Public / public-read
    // ============================================================

    /// @notice Reload cached substrates from `IPlasmaVaultGovernance(VAULT).getMarketSubstrates(MARKET_ID)`.
    /// @dev **Access control: intentionally unrestricted.** Anyone can call this function. Safety
    ///      follows from the fact that the source of truth is `getMarketSubstrates(MARKET_ID)` on
    ///      the plasma vault — atomist governance controls grants. A call to `syncSubstrates`
    ///      cannot set the cache to anything the atomist has not already granted; it can only
    ///      bring the executor cache in line with the current vault configuration.
    ///
    ///      **Why public (by design):** acts as an emergency / out-of-runbook fallback. If the
    ///      atomist forgets to call `syncSubstrates()` after `revokeMarketSubstrates(...)`,
    ///      a keeper or any third party can re-sync to close the trust-cache lag (see README
    ///      "Custodian revocation requires syncSubstrates").
    ///
    ///      **Cache-order stability — NOT guaranteed.** The substrate arrays (`balanceAccounts[]`,
    ///      `custodians[]`, `assets[]`) are rebuilt from scratch on every call, mirroring the order
    ///      returned by `getMarketSubstrates`. If atomist has inserted/removed grants between
    ///      sync calls, array indices of remaining entries may shift. Off-chain tooling MUST NOT
    ///      persist array positions across sync calls — always re-read + re-match by address.
    ///
    ///      **Mandatory singletons revert.** Reverts with `RWAMandatorySingletonMissing` if either
    ///      `STALENESS_MAX` or `BIG_CHANGE_BPS` is absent after sync, preventing a misconfigured
    ///      market from silently disabling safety guards.
    ///
    ///      **Orphaned balance accounts are forbidden.** When a previously cached balance account
    ///      is absent from the new substrate set, `syncSubstrates` requires `balances[ba] == 0`
    ///      before allowing the cache replacement; otherwise reverts with
    ///      `RWAExecutorBalanceAccountStillFunded(ba, residualBalance)`. Atomists MUST execute a
    ///      full `RWAOperationFuse.exit(...)` driving `balances[ba] = 0` before revoking the
    ///      corresponding BALANCE_ACCOUNT substrate. The accompanying `pendingProposals[ba]` and
    ///      `lastUpdated[ba]` are cleared as part of the purge — re-granting the same address
    ///      later starts from a fully clean state. See README "Operations runbooks → Adding /
    ///      Revoking a balance account" for the operator playbook.
    ///
    ///      **Event:** emits `BalanceAccountPurged(ba)` for each balance account cleared during
    ///      sync. Off-chain monitoring SHOULD alert when this fires unexpectedly. Also emits
    ///      `SubstratesSynced(balanceAccountCount, custodianCount, assetCount, stalenessMax,
    ///      bigChangeBps, dustThreshold, minUpdateInterval)` after a successful sync.
    ///      Off-chain monitors SHOULD alert when this event fires without a preceding
    ///      `grantMarketSubstrates` or `revokeMarketSubstrates` on the vault (potential griefing
    ///      or unexpected re-sync).
    function syncSubstrates() external;

    /// @notice Aggregate balance data for the balance fuse.
    /// @return totalBalance Sum of tracked balances across all balance accounts (underlying units).
    /// @return bigChangeBps Cached BIG_CHANGE_BPS threshold from substrates.
    /// @return lastCustodianUpdateTimestamp Timestamp of the last confirmed custodian update.
    function getBalanceFuseSnapshot()
        external
        view
        returns (uint256 totalBalance, uint256 bigChangeBps, uint256 lastCustodianUpdateTimestamp);

    /// @notice Minimum non-zero `lastUpdated` timestamp across all balance accounts.
    /// @return oldest The oldest non-zero `lastUpdated`, or 0 if every account has `lastUpdated == 0`.
    function getOldestUpdateTimestamp() external view returns (uint256 oldest);

    /// @notice Cached STALENESS_MAX substrate value.
    /// @return value Maximum allowed staleness in seconds before user operations are blocked.
    function stalenessMax() external view returns (uint256 value);

    /// @notice Cached BIG_CHANGE_BPS substrate value.
    /// @return value Basis-points threshold that triggers the pause flag on a new custodian update.
    function bigChangeBps() external view returns (uint256 value);

    /// @notice Cached DUST_THRESHOLD substrate value.
    /// @return value Dust allowance, expressed as percent of one base token (100 = one token).
    function dustThreshold() external view returns (uint256 value);

    /// @notice Cached MIN_UPDATE_INTERVAL substrate value.
    /// @return value Minimum seconds between confirmed custodian updates for the same balance account.
    function minUpdateInterval() external view returns (uint256 value);

    /// @notice Number of cached balance accounts. Useful for off-chain pagination.
    function balanceAccountsLength() external view returns (uint256);

    /// @notice Number of cached custodians. Useful for off-chain pagination.
    function custodiansLength() external view returns (uint256);

    /// @notice Number of cached assets. Useful for off-chain pagination.
    function assetsLength() external view returns (uint256);

    /// @notice Index getter for the cached ASSET substrate array.
    /// @param index Zero-based index into the cached assets array (`0 <= index < assetsLength()`).
    /// @return asset The asset address stored at the given index.
    function assets(uint256 index) external view returns (address asset);

    /// @notice Market identifier this executor serves.
    /// @return marketId The immutable market identifier set at construction.
    function MARKET_ID() external view returns (uint256 marketId);

    /// @notice Address of the authorized PlasmaVault.
    /// @return vault The immutable vault address set at construction.
    function VAULT() external view returns (address vault);
}
