// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRWAExecutor, RWAExecutorAction} from "./IRWAExecutor.sol";
import {RWAErrors} from "./errors/RWAErrors.sol";
import {RWASubstrateLib, RWASubstrateType} from "./lib/RWASubstrateLib.sol";

/// @title RWAExecutor
/// @notice Non-delegatecall executor contract deployed once per `(vault, marketId)` tuple.
///         Holds funds transferred by the vault during RWA enter/exit flows, tracks per
///         balance-account underlying balances, caches singleton/array substrates, enforces
///         dual-custodian balance updates, and exposes aggregate balance data.
/// @dev Only `VAULT` can call funds-moving functions. Custodian-gated functions use a cached
///      custodian list populated by `syncSubstrates()`. No ERC-7201 namespace is used: the
///      executor holds regular contract storage.
/// @author IPOR Labs
contract RWAExecutor is IRWAExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Market identifier served by this executor.
    /// @dev Bound at construction; attempting to reuse the executor slot for a different market reverts
    ///      via `RWAMultipleMarketsNotSupported` in `RWAExecutorStorageLib.getOrCreateExecutor`.
    uint256 public immutable override MARKET_ID;

    /// @notice Authorized PlasmaVault allowed to call funds-moving functions.
    /// @dev Set once at construction. Exposed publicly so off-chain tooling can verify the binding.
    address public immutable override VAULT;

    /// @notice Pending custodian proposal for a balance account.
    /// @param value Proposed new total balance in underlying units.
    /// @param proposer Custodian that submitted the proposal.
    /// @param proposedAt Timestamp when the proposal was created.
    /// @param nonce Monotonic nonce assigned at propose-time; used to bind the proposal hash.
    struct PendingProposal {
        uint256 value;
        address proposer;
        uint64 proposedAt;
        uint256 nonce;
    }

    /// @notice Tracked balance per balance account, expressed in vault underlying units.
    /// @dev Exposed as a public auto-getter for off-chain monitoring. Only `VAULT` can mutate
    ///      via `addBalance` / `removeBalance`, and custodians can overwrite via `confirmBalance`.
    mapping(address balanceAccount => uint256 underlyingBalance) public balances;

    /// @notice Timestamp of the most recent confirmed custodian update for a balance account.
    /// @dev Zero means "never updated by a custodian". Consumed by `getOldestUpdateTimestamp`
    ///      which feeds the pre-hook staleness gate.
    mapping(address balanceAccount => uint256 timestamp) public lastUpdated;

    /// @notice Latest pending proposal per balance account (overwritten on new proposals).
    /// @dev Public auto-getter returns the four `PendingProposal` fields in order
    ///      (value, proposer, proposedAt, nonce). Off-chain tooling re-derives the canonical
    ///      proposal hash via `_proposalHash`.
    mapping(address balanceAccount => PendingProposal proposal) public pendingProposals;

    /// @notice Cached BALANCE_ACCOUNT substrates. Populated/refreshed by `syncSubstrates`.
    /// @dev Order mirrors substrate grant order. Use `balanceAccountsLength()` for pagination.
    address[] public balanceAccounts;

    /// @notice Cached CUSTODIAN substrates. Populated/refreshed by `syncSubstrates`.
    /// @dev Order mirrors substrate grant order. Use `custodiansLength()` for pagination.
    ///      **Security note:** this cache is the sole source of truth for `onlyCustodian`
    ///      — revoking a custodian substrate on the vault does NOT take effect until
    ///      `syncSubstrates()` is called. Atomists/keepers MUST invoke `syncSubstrates()` in the
    ///      same runbook step / transaction as `revokeMarketSubstrates(...)`, otherwise the
    ///      revoked address can still `proposeBalance` / `confirmBalance` until the next sync.
    ///      See `contracts/fuses/rwa/README.md` ("Trust assumptions → Custodian revocation") for
    ///      the operational playbook.
    address[] public custodians;

    /// @notice Cached ASSET substrates (used for dust checks). Populated/refreshed by `syncSubstrates`.
    /// @dev Order mirrors substrate grant order. Use `assetsLength()` for pagination.
    address[] public assets;

    /// @notice Cached STALENESS_MAX singleton.
    /// @dev Unit: seconds. Maximum time since the oldest balance account update before user operations
    ///      are blocked by the pre-hook. Also doubles as the pending-proposal TTL in `confirmBalance`.
    uint256 public override stalenessMax;

    /// @notice Cached BIG_CHANGE_BPS singleton.
    /// @dev Unit: basis points (1 bps = 0.01%, 10000 bps = 100%). Threshold above which the balance
    ///      fuse and pre-hook trigger / enforce the pause flag on a new custodian update.
    uint256 public override bigChangeBps;

    /// @notice Cached DUST_THRESHOLD singleton.
    /// @dev Unit: percent of one base token scaled ×1 (so 100 = 1 token, 10_000 = 100 tokens,
    ///      1_000_000 = 10_000 tokens). Maximum executor balance of each cached asset allowed
    ///      during propose/confirm dust checks.
    uint256 public override dustThreshold;

    /// @notice Cached MIN_UPDATE_INTERVAL singleton.
    /// @dev Unit: seconds. Minimum delay between confirmed custodian balance updates for the **same**
    ///      balance account. Rate-limiting is per-account, not global: with N balance accounts a
    ///      compromised custodian pair can perform N sub-`bigChangeBps` updates per `minUpdateInterval`
    ///      window, producing a cumulative NAV drift that each individual update keeps below the
    ///      big-change pause threshold. This is an accepted trust assumption — mitigation is off-chain
    ///      monitoring of cumulative drift across balance accounts. See the "Trust assumptions" section
    ///      of `contracts/fuses/rwa/README.md` for operator guidance.
    uint256 public override minUpdateInterval;

    /// @notice Timestamp of the last confirmed custodian balance update across all balance accounts.
    /// @dev Used by the balance fuse and pre-hook to detect unprocessed custodian updates.
    uint256 public lastCustodianUpdateTimestamp;

    /// @notice Monotonic proposal nonce, incremented on every `proposeBalance`.
    /// @dev Bound into the proposal hash to prevent cross-proposal replay within the same account.
    uint256 public nonce;

    /// @dev Denominator for `dustThreshold` when interpreted as a percent of one base token
    ///      (`allowed = 10^decimals * dustThreshold / DUST_THRESHOLD_DENOMINATOR`).
    uint256 private constant DUST_THRESHOLD_DENOMINATOR = 100;

    /// @notice Emitted when a custodian proposes a balance update.
    event BalanceProposed(
        address  balanceAccount,
        address  proposer,
        uint256 newValue,
        uint256 nonce,
        uint64 proposedAt,
        bytes32 proposalHash
    );

    /// @notice Emitted when a custodian confirms a pending balance update.
    event BalanceConfirmed(
        address  balanceAccount, address  confirmer, uint256 oldValue, uint256 newValue, uint256 nonce
    );

    /// @notice Emitted when a new `proposeBalance` call overwrites an un-confirmed pending proposal.
    /// @dev The previous proposer's hash becomes permanently invalid; off-chain tooling that tracks
    ///      pending proposals MUST listen to this event to discard stale hashes.
    event ProposalOverwritten(
        address  balanceAccount,
        address  oldProposer,
        address  newProposer,
        uint256 oldNonce,
        uint256 newNonce
    );

    /// @notice Emitted when the operation fuse adds or removes balance for an account.
    event BalanceChangedByFuse(address  balanceAccount, int256 delta, uint256 newBalance);

    /// @notice Emitted after a batch of external actions has been executed.
    event ActionsExecuted(uint256 count);

    /// @notice Emitted by `syncSubstrates` for each balance account that is purged from the cache
    ///         because it has been revoked from the vault substrate set. The per-account mappings
    ///         (`balances`, `pendingProposals`, `lastUpdated`) are reset to zero alongside the cache
    ///         removal.
    /// @dev Off-chain monitoring SHOULD alert when this event fires unexpectedly — purges represent
    ///      a substrate-set reduction that operators must explicitly authorize via
    ///      `revokeMarketSubstrates(...)` on the vault. See `contracts/fuses/rwa/README.md`
    ///      ("Operations runbooks → 13.8 Adding/Revoking a balance account").
    /// @param balanceAccount The balance account that was purged.
    event BalanceAccountPurged(address balanceAccount);

    /// @notice Emitted after `syncSubstrates` refreshes the cache.
    event SubstratesSynced(
        uint256 balanceAccountCount,
        uint256 custodianCount,
        uint256 assetCount,
        uint256 stalenessMax,
        uint256 bigChangeBps,
        uint256 dustThreshold,
        uint256 minUpdateInterval
    );

    /// @notice Emitted when `withdrawAssetBalance` sweeps tokens back to the vault.
    event AssetWithdrawn(address  asset, uint256 amount);

    /// @notice Restricts access to the authorized PlasmaVault.
    modifier onlyVault() {
        if (msg.sender != VAULT) revert RWAErrors.RWAExecutorUnauthorizedVault();
        _;
    }

    /// @notice Restricts access to addresses currently present in the cached custodian list.
    /// @dev The check reads the `custodians[]` cache, not the vault substrate list. A custodian
    ///      revoked on the vault REMAINS authorized here until `syncSubstrates()` is called.
    ///      See the `custodians` storage docstring and README "Trust assumptions".
    modifier onlyCustodian() {
        if (!_isCustodian(msg.sender)) {
            revert RWAErrors.RWAExecutorUnauthorizedCustodian(msg.sender);
        }
        _;
    }

    /// @param marketId_ Market identifier bound to this executor (must be non-zero).
    /// @param vault_ Authorized PlasmaVault address (must be non-zero).
    constructor(uint256 marketId_, address vault_) {
        if (marketId_ == 0) revert RWAErrors.RWAExecutorZeroMarketId();
        if (vault_ == address(0)) revert RWAErrors.RWAExecutorZeroAddressConstructor();
        MARKET_ID = marketId_;
        VAULT = vault_;
    }

    // ============================================================
    // Vault-gated mutations
    // ============================================================

    /// @inheritdoc IRWAExecutor
    function addBalance(address balanceAccount_, uint256 valueInUnderlying_) external override onlyVault {
        int256 signedDelta = valueInUnderlying_.toInt256();
        balances[balanceAccount_] += valueInUnderlying_;
        emit BalanceChangedByFuse(balanceAccount_, signedDelta, balances[balanceAccount_]);
    }

    /// @inheritdoc IRWAExecutor
    function removeBalance(address balanceAccount_, uint256 valueInUnderlying_, address asset_, uint256 tokenAmount_)
        external
        override
        onlyVault
        nonReentrant
    {
        uint256 current = balances[balanceAccount_];
        if (valueInUnderlying_ > current) {
            revert RWAErrors.RWAExitExceedsTrackedBalance(balanceAccount_, valueInUnderlying_, current);
        }
        int256 signedDelta = -valueInUnderlying_.toInt256();
        balances[balanceAccount_] = current - valueInUnderlying_;
        emit BalanceChangedByFuse(balanceAccount_, signedDelta, balances[balanceAccount_]);

        if (tokenAmount_ > 0) {
            IERC20(asset_).safeTransfer(VAULT, tokenAmount_);
        }
    }

    /// @inheritdoc IRWAExecutor
    function execute(RWAExecutorAction[] calldata actions_) external override onlyVault nonReentrant {
        uint256 len = actions_.length;
        for (uint256 i; i < len; ++i) {
            Address.functionCall(actions_[i].target, actions_[i].data);
        }
        emit ActionsExecuted(len);
    }

    /// @inheritdoc IRWAExecutor
    function withdrawAssetBalance(address asset_) external override onlyVault {
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        if (bal > 0) {
            IERC20(asset_).safeTransfer(VAULT, bal);
        }
        emit AssetWithdrawn(asset_, bal);
    }

    // ============================================================
    // Custodian dual-approval
    // ============================================================

    /// @inheritdoc IRWAExecutor
    function proposeBalance(address balanceAccount_, uint256 newValue_) external override onlyCustodian nonReentrant {
        // Authorization-first — validate `balanceAccount_` against the vault substrate set
        // (source of truth) before any other check. Closes the race window between
        // `revokeMarketSubstrates` and `syncSubstrates` — a compromised custodian pair cannot
        // inject phantom balance into a balance account that has been revoked from the vault.
        // Mirrors the order applied in `confirmBalance` for consistency.
        _requireBalanceAccountGrantedOnVault(balanceAccount_);
        // Defense-in-depth: also require the BA to be present in the local cache. Forces
        // `syncSubstrates()` to be called when the cache drifts behind the vault substrate set.
        _requireBalanceAccountInCache(balanceAccount_);

        _checkDust();

        uint256 newNonce = ++nonce;

        PendingProposal memory previous = pendingProposals[balanceAccount_];
        if (previous.proposer != address(0)) {
            emit ProposalOverwritten(balanceAccount_, previous.proposer, msg.sender, previous.nonce, newNonce);
        }

        uint64 nowTs = uint64(block.timestamp);
        pendingProposals[balanceAccount_] =
            PendingProposal({value: newValue_, proposer: msg.sender, proposedAt: nowTs, nonce: newNonce});

        bytes32 h = _proposalHash(balanceAccount_, newValue_, msg.sender, nowTs, newNonce);
        emit BalanceProposed(balanceAccount_, msg.sender, newValue_, newNonce, nowTs, h);
    }

    /// @inheritdoc IRWAExecutor
    function confirmBalance(address balanceAccount_, bytes32 proposalHash_)
        external
        override
        onlyCustodian
        nonReentrant
    {
        // 0. Authorization-first — validate `balanceAccount_` against the vault substrate set
        //    (source of truth). If the account has been revoked, reject before any further checks
        //    so off-chain monitoring sees a clean `RWAUnsupportedSubstrate` signal.
        _requireBalanceAccountGrantedOnVault(balanceAccount_);
        // Defense-in-depth: also require the BA to be present in the local cache. Forces
        // `syncSubstrates()` to be called when the cache drifts behind the vault substrate set.
        _requireBalanceAccountInCache(balanceAccount_);

        PendingProposal memory pending = pendingProposals[balanceAccount_];
        // 1. no pending proposal
        if (pending.proposer == address(0)) {
            revert RWAErrors.RWAExecutorNoPendingProposal(balanceAccount_);
        }
        // 2. same proposer/confirmer
        if (pending.proposer == msg.sender) {
            revert RWAErrors.RWAExecutorSameProposerAndConfirmer(msg.sender);
        }
        // 3. TTL check (proposal expiration uses stalenessMax as TTL per plan)
        uint256 nowTs = block.timestamp;
        if (nowTs - pending.proposedAt > stalenessMax) {
            revert RWAErrors.RWAExecutorProposalExpired(pending.proposedAt, nowTs, stalenessMax);
        }
        // 4. dust check
        _checkDust();
        // 5. hash verification
        bytes32 expected = _proposalHash(balanceAccount_, pending.value, pending.proposer, pending.proposedAt, pending.nonce);
        if (expected != proposalHash_) {
            revert RWAErrors.RWAExecutorProposalHashMismatch(expected, proposalHash_);
        }
        // 6. MIN_UPDATE_INTERVAL (exempt first update where lastUpdated == 0)
        uint256 last = lastUpdated[balanceAccount_];
        if (last != 0 && nowTs - last < minUpdateInterval) {
            revert RWAErrors.RWAExecutorMinUpdateIntervalNotMet(last, nowTs, minUpdateInterval);
        }
        // 7. update balance + timestamps
        uint256 oldValue = balances[balanceAccount_];
        balances[balanceAccount_] = pending.value;
        lastUpdated[balanceAccount_] = nowTs;
        lastCustodianUpdateTimestamp = nowTs;
        // 8. clear pending slot
        delete pendingProposals[balanceAccount_];
        // 9. emit
        emit BalanceConfirmed(balanceAccount_, msg.sender, oldValue, pending.value, pending.nonce);
    }

    // ============================================================
    // Substrate cache
    // ============================================================

    /// @inheritdoc IRWAExecutor
    function syncSubstrates() external override {
        bytes32[] memory substrates = IPlasmaVaultGovernance(VAULT).getMarketSubstrates(MARKET_ID);

        // Enforce orphaned-balance invariant before replacing the cache. Snapshot the current
        // balance-account cache, decode the new BALANCE_ACCOUNT set into memory, and require
        // `balances[oldBA] == 0` for any account being removed. The purge also clears
        // `pendingProposals[oldBA]` and `lastUpdated[oldBA]` so re-granting the same address
        // later starts from a fully clean state.
        address[] memory oldBAs = balanceAccounts;
        address[] memory newBAs = _extractBalanceAccountsFromSubstrates(substrates);
        _purgeOrphanedBalanceAccounts(oldBAs, newBAs);

        // Clear existing caches: dynamic arrays are deleted and singletons reset to 0 before
        // re-population. The per-balance-account mappings (`balances`, `lastUpdated`,
        // `pendingProposals`) are NOT cleared here by design — mappings cannot be wiped wholesale
        // in Solidity, and BA-specific entries are handled per-account by
        // `_purgeOrphanedBalanceAccounts` above (which also enforces the orphaned-balance invariant
        // requiring `balances[oldBA] == 0` before purge).
        delete balanceAccounts;
        delete custodians;
        delete assets;
        stalenessMax = 0;
        bigChangeBps = 0;
        dustThreshold = 0;
        minUpdateInterval = 0;

        bool seenStaleness;
        bool seenBigChange;
        bool seenDust;
        bool seenMinInterval;

        uint256 len = substrates.length;
        for (uint256 i; i < len; ++i) {
            bytes32 sub = substrates[i];
            RWASubstrateType t = RWASubstrateLib.decodeSubstrateType(sub);

            if (t == RWASubstrateType.ASSET) {
                assets.push(RWASubstrateLib.decodeAddressPayload(sub));
            } else if (t == RWASubstrateType.CUSTODIAN) {
                custodians.push(RWASubstrateLib.decodeAddressPayload(sub));
            } else if (t == RWASubstrateType.BALANCE_ACCOUNT) {
                address ba = RWASubstrateLib.decodeAddressPayload(sub);
                // Duplicate balance accounts in the substrate set always indicate a governance
                // misconfiguration — refuse to repopulate the cache instead of silently tolerating
                // them. O(n^2) cost is acceptable: `n` (number of BAs) is small (single digits in
                // practice) and `syncSubstrates` is a governance-frequency operation.
                uint256 baLen = balanceAccounts.length;
                for (uint256 j; j < baLen; ++j) {
                    if (balanceAccounts[j] == ba) {
                        revert RWAErrors.RWADuplicateBalanceAccountSubstrate(ba);
                    }
                }
                balanceAccounts.push(ba);
            } else if (t == RWASubstrateType.STALENESS_MAX) {
                if (seenStaleness) {
                    revert RWAErrors.RWADuplicateSingletonSubstrate(uint8(RWASubstrateType.STALENESS_MAX));
                }
                seenStaleness = true;
                stalenessMax = RWASubstrateLib.decodeUint248Payload(sub);
            } else if (t == RWASubstrateType.BIG_CHANGE_BPS) {
                if (seenBigChange) {
                    revert RWAErrors.RWADuplicateSingletonSubstrate(uint8(RWASubstrateType.BIG_CHANGE_BPS));
                }
                seenBigChange = true;
                bigChangeBps = RWASubstrateLib.decodeUint248Payload(sub);
            } else if (t == RWASubstrateType.DUST_THRESHOLD) {
                if (seenDust) {
                    revert RWAErrors.RWADuplicateSingletonSubstrate(uint8(RWASubstrateType.DUST_THRESHOLD));
                }
                seenDust = true;
                dustThreshold = RWASubstrateLib.decodeUint248Payload(sub);
            } else if (t == RWASubstrateType.MIN_UPDATE_INTERVAL) {
                if (seenMinInterval) {
                    revert RWAErrors.RWADuplicateSingletonSubstrate(uint8(RWASubstrateType.MIN_UPDATE_INTERVAL));
                }
                seenMinInterval = true;
                minUpdateInterval = RWASubstrateLib.decodeUint248Payload(sub);
            } else if (t == RWASubstrateType.TARGET) {
                // Target substrates are consumed by the operation fuse directly via isMarketSubstrateGranted;
                // the executor does not need to cache them.
            } else {
                // UNDEFINED / unknown — ignored (defensive; decodeSubstrateType would have reverted
                // for out-of-range raw bytes already).
            }
        }

        // Mandatory singletons: stalenessMax and bigChangeBps must be configured.
        // Without stalenessMax the staleness gate is disabled; without bigChangeBps the big-change
        // pause is silently skipped — both leave the vault unprotected.
        if (stalenessMax == 0) {
            revert RWAErrors.RWAMandatorySingletonMissing(uint8(RWASubstrateType.STALENESS_MAX));
        }
        if (bigChangeBps == 0) {
            revert RWAErrors.RWAMandatorySingletonMissing(uint8(RWASubstrateType.BIG_CHANGE_BPS));
        }

        emit SubstratesSynced(
            balanceAccounts.length,
            custodians.length,
            assets.length,
            stalenessMax,
            bigChangeBps,
            dustThreshold,
            minUpdateInterval
        );
    }

    // ============================================================
    // Views
    // ============================================================

    /// @inheritdoc IRWAExecutor
    function getBalanceFuseSnapshot()
        external
        view
        override
        returns (uint256 totalBalance, uint256 bigChangeBps_, uint256 lastCustodianUpdateTimestamp_)
    {
        uint256 len = balanceAccounts.length;
        for (uint256 i; i < len; ++i) {
            totalBalance += balances[balanceAccounts[i]];
        }
        bigChangeBps_ = bigChangeBps;
        lastCustodianUpdateTimestamp_ = lastCustodianUpdateTimestamp;
    }

    /// @inheritdoc IRWAExecutor
    function getOldestUpdateTimestamp() external view override returns (uint256 oldest) {
        uint256 len = balanceAccounts.length;
        for (uint256 i; i < len; ++i) {
            uint256 ts = lastUpdated[balanceAccounts[i]];
            if (ts != 0 && (oldest == 0 || ts < oldest)) {
                oldest = ts;
            }
        }
    }

    /// @inheritdoc IRWAExecutor
    function balanceAccountsLength() external view override returns (uint256) {
        return balanceAccounts.length;
    }

    /// @inheritdoc IRWAExecutor
    function custodiansLength() external view override returns (uint256) {
        return custodians.length;
    }

    /// @inheritdoc IRWAExecutor
    function assetsLength() external view override returns (uint256) {
        return assets.length;
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    /// @dev Linear scan over the cached custodian list.
    /// @param who_ Address to check.
    /// @return True if `who_` is found in the cached custodian array.
    function _isCustodian(address who_) internal view returns (bool) {
        uint256 len = custodians.length;
        for (uint256 i; i < len; ++i) {
            if (custodians[i] == who_) return true;
        }
        return false;
    }

    /// @dev Defense-in-depth check: revert if `balanceAccount_` is missing from the cached
    ///      `balanceAccounts[]` array. Used by `proposeBalance` / `confirmBalance` in addition
    ///      to `_requireBalanceAccountGrantedOnVault`. Detects cache drift (vault grants but
    ///      no `syncSubstrates()` yet) and forces operators to refresh the cache before custodian
    ///      operations resume.
    /// @param balanceAccount_ Balance account to look up in the cache.
    function _requireBalanceAccountInCache(address balanceAccount_) internal view {
        uint256 len = balanceAccounts.length;
        for (uint256 i; i < len; ++i) {
            if (balanceAccounts[i] == balanceAccount_) return;
        }
        revert RWAErrors.RWAExecutorBalanceAccountNotInCache(balanceAccount_);
    }

    /// @dev Revert if `balanceAccount_` is not currently granted as a BALANCE_ACCOUNT substrate
    ///      on the vault. Uses `IPlasmaVaultGovernance.isMarketSubstrateGranted` (external call)
    ///      — substrate state lives in the vault's storage, not the executor's, so we cannot
    ///      reuse the storage-reading helpers in `PlasmaVaultConfigLib`. Reverts with the same
    ///      `RWAUnsupportedSubstrate` selector emitted by the fuse-side validation in
    ///      `RWAOperationFuse._validateSubstratesAndActions` for off-chain log consistency.
    /// @param balanceAccount_ Address to validate against the vault substrate set.
    function _requireBalanceAccountGrantedOnVault(address balanceAccount_) internal view {
        bytes32 encoded = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccount_);
        if (!IPlasmaVaultGovernance(VAULT).isMarketSubstrateGranted(MARKET_ID, encoded)) {
            revert RWAErrors.RWAUnsupportedSubstrate(uint8(RWASubstrateType.BALANCE_ACCOUNT), encoded);
        }
    }

    /// @dev Decode only BALANCE_ACCOUNT substrates from `substrates_` into a tightly-sized memory
    ///      array. Two-pass scheme allocates exactly `count` slots in the first pass and fills
    ///      them in the second. Used by `syncSubstrates` to determine the new balance-account
    ///      set before storage replacement.
    /// @param substrates_ Substrate set returned by `getMarketSubstrates(MARKET_ID)`.
    /// @return newBAs Memory array of balance accounts referenced by the new substrate set.
    function _extractBalanceAccountsFromSubstrates(bytes32[] memory substrates_)
        private
        pure
        returns (address[] memory newBAs)
    {
        uint256 len = substrates_.length;
        uint256 count;
        for (uint256 i; i < len; ++i) {
            if (RWASubstrateLib.decodeSubstrateType(substrates_[i]) == RWASubstrateType.BALANCE_ACCOUNT) {
                ++count;
            }
        }
        newBAs = new address[](count);
        uint256 idx;
        for (uint256 i; i < len; ++i) {
            bytes32 sub = substrates_[i];
            if (RWASubstrateLib.decodeSubstrateType(sub) == RWASubstrateType.BALANCE_ACCOUNT) {
                newBAs[idx++] = RWASubstrateLib.decodeAddressPayload(sub);
            }
        }
    }

    /// @dev For every balance account present in `oldBAs_` but absent from `newBAs_`, enforce
    ///      that `balances[oldBA] == 0` and clear the per-account mappings (`balances`,
    ///      `pendingProposals`, `lastUpdated`). Reverts on the first violation with
    ///      `RWAExecutorBalanceAccountStillFunded`. Emits `BalanceAccountPurged(oldBA)` for each
    ///      cleared account. Atomicity: a single funded BA aborts the entire sync.
    /// @param oldBAs_ Snapshot of `balanceAccounts[]` taken before substrate-set replacement.
    /// @param newBAs_ Balance accounts in the incoming substrate set.
    function _purgeOrphanedBalanceAccounts(address[] memory oldBAs_, address[] memory newBAs_) private {
        uint256 oldLen = oldBAs_.length;
        uint256 newLen = newBAs_.length;
        for (uint256 i; i < oldLen; ++i) {
            address oldBA = oldBAs_[i];
            bool stillPresent;
            for (uint256 j; j < newLen; ++j) {
                if (oldBA == newBAs_[j]) {
                    stillPresent = true;
                    break;
                }
            }
            if (!stillPresent) {
                uint256 residual = balances[oldBA];
                if (residual != 0) {
                    revert RWAErrors.RWAExecutorBalanceAccountStillFunded(oldBA, residual);
                }
                delete balances[oldBA];
                delete pendingProposals[oldBA];
                delete lastUpdated[oldBA];
                emit BalanceAccountPurged(oldBA);
            }
        }
    }

    /// @notice Verifies that no cached asset has a balance above the dust allowance.
    /// @dev Dust check: for each cached asset, the executor balance must be less than or equal to
    ///      `dustThreshold * 10^decimals / 100` (i.e. `dustThreshold` percent of one base token).
    ///      If `dustThreshold == 0`, no balance is allowed. Reverts with `RWAExecutorDustCheckFailed`
    ///      if any asset exceeds the allowance. Only cached assets (from `syncSubstrates`) are checked,
    ///      so newly-added ASSET substrates require a `syncSubstrates` call to participate.
    function _checkDust() internal view {
        uint256 len = assets.length;
        uint256 dt = dustThreshold;
        for (uint256 i; i < len; ++i) {
            address asset = assets[i];
            uint256 bal = IERC20(asset).balanceOf(address(this));
            uint256 allowed = (10 ** IERC20Metadata(asset).decimals()) * dt / DUST_THRESHOLD_DENOMINATOR;
            if (bal > allowed) {
                revert RWAErrors.RWAExecutorDustCheckFailed(asset, bal, allowed);
            }
        }
    }

    /// @notice Canonical proposal hash used by `proposeBalance` emission and `confirmBalance` verification.
    /// @dev Binds `address(this)` (executor), `block.chainid`, and `balanceAccount_` to prevent
    ///      cross-executor, cross-chain, and cross-account hash collisions.
    /// @param balanceAccount_ Balance account targeted by the proposal.
    /// @param value_ Proposed new total balance (underlying units).
    /// @param proposer_ Custodian that submitted the proposal.
    /// @param proposedAt_ Block timestamp at which the proposal was recorded.
    /// @param nonce_ Monotonic proposal nonce assigned at propose-time.
    /// @return Canonical hash binding every field listed above.
    function _proposalHash(
        address balanceAccount_,
        uint256 value_,
        address proposer_,
        uint64 proposedAt_,
        uint256 nonce_
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), block.chainid, balanceAccount_, value_, proposer_, proposedAt_, nonce_));
    }
}
