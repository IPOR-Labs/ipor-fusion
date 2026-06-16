// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title RWAErrors
/// @notice Centralized custom errors for the RWA fuse family (operation, balance, pre-hook, executor, unpause, rescue).
/// @dev All errors carry diagnostic parameters to aid debugging and off-chain monitoring.
/// @author IPOR Labs
library RWAErrors {
    // ============================================================
    // Substrate errors
    // ============================================================

    /// @notice Thrown when a substrate type is not recognized by the library.
    /// @param substrateType The raw 8-bit type discriminator decoded from the substrate.
    /// @param encoded The raw bytes32 substrate value for debugging.
    error RWAUnsupportedSubstrate(uint8 substrateType, bytes32 encoded);

    /// @notice Thrown when a singleton substrate appears more than once in the market configuration.
    /// @param substrateType The substrate type whose singleton invariant was violated.
    error RWADuplicateSingletonSubstrate(uint8 substrateType);

    /// @notice Thrown when a mandatory singleton substrate is missing (value == 0) after syncSubstrates.
    /// @param substrateType The substrate type that must be configured.
    error RWAMandatorySingletonMissing(uint8 substrateType);

    /// @notice Thrown when an encoded uint248 payload would overflow the 248-bit slot.
    /// @param substrateType The substrate type being encoded.
    /// @param value The offending value that exceeds uint248 max.
    error RWASubstratePayloadOverflow(uint8 substrateType, uint256 value);

    // ============================================================
    // Operation fuse errors
    // ============================================================

    /// @notice Thrown when the operation fuse is constructed with marketId == 0.
    error RWAZeroMarketId();

    /// @notice Thrown when a zero address is provided where a non-zero address is required.
    error RWAZeroAddress();

    /// @notice Thrown when an action's calldata is shorter than 4 bytes (no selector can be derived).
    /// @param actionIndex The index of the offending action in the array.
    /// @param dataLength The actual length of the calldata provided.
    error RWAActionDataTooShort(uint256 actionIndex, uint256 dataLength);

    /// @notice Thrown when attempting to exit more balance than is tracked for the account.
    /// @param balanceAccount The balance account being decremented.
    /// @param valueInUnderlying The amount (in underlying units) attempted to remove.
    /// @param trackedBalance The currently tracked balance for the account.
    error RWAExitExceedsTrackedBalance(address balanceAccount, uint256 valueInUnderlying, uint256 trackedBalance);

    /// @notice Thrown when the PriceOracleMiddleware address is not configured on the plasma vault.
    error RWAPriceOracleNotSet();

    /// @notice Thrown when the PriceOracleMiddleware returns a zero price for an asset.
    /// @param asset The asset whose price came back as zero.
    error RWAInvalidPrice(address asset);

    /// @notice Thrown when both the asset amount and the actions array are empty on enter/exit.
    error RWAEmptyAssetAndActions();

    /// @notice Thrown when trying to reuse an executor deployed for a different marketId.
    /// @param existingMarketId Market identifier bound to the already-deployed executor.
    /// @param requestedMarketId Market identifier requested by the caller.
    error RWAMultipleMarketsNotSupported(uint256 existingMarketId, uint256 requestedMarketId);

    /// @notice Thrown when the operation fuse exit is invoked before the executor was deployed.
    error RWAOperationExecutorNotDeployed();

    // ============================================================
    // Executor errors
    // ============================================================

    /// @notice Thrown when a function restricted to the vault is called by another address.
    error RWAExecutorUnauthorizedVault();

    /// @notice Thrown when a function restricted to cached custodians is called by an unknown address.
    /// @param caller The actual caller that failed the custodian check.
    error RWAExecutorUnauthorizedCustodian(address caller);

    /// @notice Thrown when the dust check fails during propose or confirm.
    /// @param asset The asset that exceeded the dust allowance.
    /// @param balance The current executor balance of the asset.
    /// @param allowed The maximum balance allowed by the dust threshold.
    error RWAExecutorDustCheckFailed(address asset, uint256 balance, uint256 allowed);

    /// @notice Thrown when the same custodian both proposed and confirmed a balance update.
    /// @param custodian The custodian that attempted double approval.
    error RWAExecutorSameProposerAndConfirmer(address custodian);

    /// @notice Thrown when the hash provided for confirmation does not match the stored pending proposal.
    /// @param expected The hash computed from the stored pending proposal.
    /// @param given The hash supplied by the caller.
    error RWAExecutorProposalHashMismatch(bytes32 expected, bytes32 given);

    /// @notice Thrown when the pending proposal is older than the configured TTL (stalenessMax).
    /// @param proposedAt The timestamp when the proposal was created.
    /// @param now_ The current block timestamp.
    /// @param ttl The maximum time-to-live for the proposal.
    error RWAExecutorProposalExpired(uint256 proposedAt, uint256 now_, uint256 ttl);

    /// @notice Thrown when confirming a balance before the min-update-interval has elapsed since the last update.
    /// @param lastUpdatedAt The timestamp of the previous confirmed update.
    /// @param now_ The current block timestamp.
    /// @param minInterval The configured minimum interval between updates.
    error RWAExecutorMinUpdateIntervalNotMet(uint256 lastUpdatedAt, uint256 now_, uint256 minInterval);

    /// @notice Thrown when confirm is called without a pending proposal for the balance account.
    /// @param balanceAccount The balance account that has no pending proposal.
    error RWAExecutorNoPendingProposal(address balanceAccount);

    /// @notice Thrown when the executor constructor receives a zero vault address.
    error RWAExecutorZeroAddressConstructor();

    /// @notice Thrown when the executor constructor receives a zero marketId.
    error RWAExecutorZeroMarketId();

    /// @notice Thrown by `syncSubstrates` when a balance account being removed from the substrate
    ///         set still has a non-zero tracked balance. Atomists must execute a full `exit`
    ///         (driving `balances[ba] == 0`) before revoking the BALANCE_ACCOUNT substrate.
    /// @param balanceAccount The balance account being removed.
    /// @param residualBalance The non-zero balance preventing removal.
    error RWAExecutorBalanceAccountStillFunded(address balanceAccount, uint256 residualBalance);

    /// @notice Thrown by `proposeBalance` / `confirmBalance` when the supplied balance account is
    ///         not present in the cached `balanceAccounts[]` array. Defense-in-depth in addition
    ///         to the vault-substrate check; signals a desynchronized cache that must be repaired
    ///         via `syncSubstrates()` before custodian operations can resume.
    /// @param balanceAccount The balance account missing from the cache.
    error RWAExecutorBalanceAccountNotInCache(address balanceAccount);

    // ============================================================
    // Pre-hook errors
    // ============================================================

    /// @notice Thrown when the pause flag is set and a gated user operation is attempted.
    error RWAPreHookPaused();

    /// @notice Thrown when at least one balance account has not been updated within stalenessMax.
    /// @param oldestUpdate The oldest non-zero lastUpdated timestamp across balance accounts.
    /// @param now_ The current block timestamp.
    /// @param stalenessMax The maximum allowed staleness in seconds.
    error RWAPreHookStale(uint256 oldestUpdate, uint256 now_, uint256 stalenessMax);

    /// @notice Thrown when the pre-hook detects an unprocessed big-change event on the executor.
    /// @param previousTotal Last total balance observed by the balance fuse.
    /// @param currentTotal Current total balance reported by the executor.
    /// @param thresholdBps Configured big-change threshold in basis points.
    error RWAPreHookBigChangeDetected(uint256 previousTotal, uint256 currentTotal, uint256 thresholdBps);

    /// @notice Thrown when the pre-hook runs and the executor has not yet been deployed.
    error RWAPreHookExecutorNotDeployed();

    // ============================================================
    // Unpause errors
    // ============================================================

    /// @notice Thrown when the recovered signer of the unpause signature is not an atomist.
    /// @param signer The ECDSA-recovered signer address.
    error RWAUnpauseSignerNotAtomist(address signer);

    /// @notice Thrown when the signed total balance does not match the current executor balance.
    /// @param signed The total balance signed by the atomist.
    /// @param current The current total balance reported by the executor.
    error RWAUnpauseBalanceMismatch(uint256 signed, uint256 current);

    /// @notice Thrown when unpause is attempted but the pause flag is not set (or the executor is not deployed).
    error RWAUnpauseNotPaused();

    /// @notice Thrown when the nonce has already been consumed by a previous unpause.
    /// @param nonce The nonce attempted to be reused.
    error RWAUnpauseSignatureReplay(uint256 nonce);

    /// @notice Thrown when the unpause signature has passed its expiration timestamp.
    error RWAUnpauseSignatureExpired();

    // ============================================================
    // Rescue errors
    // ============================================================

    /// @notice Thrown when rescue is invoked before the executor has been deployed.
    error RWARescueExecutorNotDeployed();

    /// @notice Thrown when rescue is attempted on an asset that is currently registered as an
    ///         ASSET substrate on the executor. Rescue is intended for airdrops and accidentally
    ///         transferred tokens only — sweeping a tracked asset out-of-band would desynchronize
    ///         the strategy state between custodian confirms.
    /// @param asset The tracked asset that the caller attempted to rescue.
    error RWARescueOfTrackedAssetForbidden(address asset);

    // ============================================================
    // Substrate cache errors
    // ============================================================

    /// @notice Thrown by `syncSubstrates` when the same balance-account address appears more than
    ///         once in the substrate set. Duplicates always indicate a governance misconfiguration,
    ///         so the executor refuses to repopulate the cache instead of silently tolerating them.
    /// @param balanceAccount The duplicated balance-account substrate.
    error RWADuplicateBalanceAccountSubstrate(address balanceAccount);
}
