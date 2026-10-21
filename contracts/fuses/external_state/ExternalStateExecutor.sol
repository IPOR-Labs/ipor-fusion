// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IExternalStateExecutor, ExternalStateExecutorAction} from "./IExternalStateExecutor.sol";
import {ExternalStateErrors} from "./errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib, ExternalStateSubstrateType} from "./lib/ExternalStateSubstrateLib.sol";

/// @title ExternalStateExecutor
/// @notice Non-delegatecall executor contract deployed once per `(vault, marketId)` tuple.
///         Holds funds transferred by the vault during ExternalState enter/exit flows, tracks per
///         balance-account underlying balances, caches singleton/array substrates, enforces
///         dual-custodian balance updates, and exposes aggregate balance data.
/// @dev Only `VAULT` can call funds-moving functions. Custodian-gated functions use a cached
///      custodian list populated by `syncSubstrates()`. No ERC-7201 namespace is used: the
///      executor holds regular contract storage.
/// @author IPOR Labs
contract ExternalStateExecutor is IExternalStateExecutor, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice Market identifier served by this executor.
    /// @dev Bound at construction; attempting to reuse the executor slot for a different market reverts
    ///      via `ExternalStateMultipleMarketsNotSupported` in `ExternalStateExecutorStorageLib.getOrCreateExecutor`.
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
    ///      via `addBalance` / `removeBalance`, and custodians can overwrite via `confirmBalance`, but only
    ///      while the value still equals `proposalBaseBalance` (no ALPHA flow on the account since the proposal).
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

    /// @notice `balances[balanceAccount]` as it was when the latest proposal for the account was stored.
    /// @dev Kept outside `PendingProposal` so the `pendingProposals` getter and the proposal hash stay unchanged.
    ///      Written on every `proposeBalance` (also when it overwrites a proposal) and read only by `confirmBalance`
    ///      while a proposal exists, so it is never cleared. Between propose and confirm only `addBalance` /
    ///      `removeBalance` (ALPHA `enter` / `exit`) change `balances[]`, so a difference means a flow ran after
    ///      the proposal was stored. `confirmBalance` requires `balances[ba] == proposalBaseBalance[ba]`.
    mapping(address balanceAccount => uint256 balance) public proposalBaseBalance;

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
    ///      See `contracts/fuses/external_state/README.md` ("Trust assumptions → Custodian revocation") for
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
    ///      1_000_000 = 10_000 tokens). Maximum amount of each cached asset that may be credited to a
    ///      balance account but still sit on the executor (see `unforwardedCredit`) during propose/confirm
    ///      dust checks. Tokens sent to the executor by third parties are not counted (IL-8739), except up to a stale credit (see `sweepSurplus`).
    uint256 public override dustThreshold;

    /// @notice Per asset, the amount of tokens that entered the executor through the vault path and have not left it yet.
    /// @dev "Vault path" means `addBalance` (enter), tokens returned to the executor by external actions inside
    ///      `execute`, and, in the opposite direction, `removeBalance`, tokens spent by `execute` and
    ///      `withdrawAssetBalance`. Only `onlyVault` functions change it, always from balance differences
    ///      measured inside one vault call, so a plain ERC20 transfer to the executor (a donation) never
    ///      moves it. `_checkDust` reads it instead of the raw token balance: credited-but-unforwarded tokens
    ///      would be overwritten by a custodian report and drop out of NAV, donations are not in `balances[]`
    ///      and cannot be lost that way. `sweepSurplus` moves exactly the part of the balance that is not
    ///      covered by this counter.
    ///      `removeBalance` debits the credit by the exited amount whatever the origin of the tokens, so book a
    ///      custody return with `exit` only while the credit is 0 (IL-8739).
    mapping(address asset => uint256 amount) public override unforwardedCredit;

    /// @notice Cached MIN_UPDATE_INTERVAL singleton.
    /// @dev Unit: seconds. Minimum delay between confirmed custodian balance updates for the **same**
    ///      balance account. Rate-limiting is per-account, not global: with N balance accounts a
    ///      compromised custodian pair can perform N sub-`bigChangeBps` updates per `minUpdateInterval`
    ///      window, producing a cumulative NAV drift that each individual update keeps below the
    ///      big-change pause threshold. This is an accepted trust assumption — mitigation is off-chain
    ///      monitoring of cumulative drift across balance accounts. See the "Trust assumptions" section
    ///      of `contracts/fuses/external_state/README.md` for operator guidance.
    uint256 public override minUpdateInterval;

    /// @notice Timestamp of the last confirmed custodian balance update across all balance accounts.
    /// @dev Informational only — NOT used by the circuit breaker. `block.timestamp` is not unique
    ///      per confirmation: two confirms in the same block share this value, which is exactly the
    ///      defect this field's former use as the breaker watermark caused (IL-7969). The breaker and
    ///      pre-hook now use `confirmCount`, a strictly monotonic per-confirmation counter, instead.
    ///      This field is kept only for off-chain staleness observability.
    uint256 public lastCustodianUpdateTimestamp;

    /// @notice Monotonic proposal nonce, incremented on every `proposeBalance`.
    /// @dev Bound into the proposal hash to prevent cross-proposal replay within the same account.
    uint256 public nonce;

    /// @notice Monotonic counter of confirmed custodian balance updates across all balance accounts.
    /// @dev Incremented on every successful `confirmBalance`, regardless of `block.timestamp`. This is
    ///      the circuit-breaker watermark consumed via `getBalanceFuseSnapshot()` by the balance fuse
    ///      and the pre-hook: unlike a timestamp, a strictly increasing counter can never collide
    ///      between two confirms in the same block, so every confirm is guaranteed to be observed by
    ///      the big-change check exactly once (IL-7969 fix).
    uint256 public confirmCount;

    /// @dev Denominator for `dustThreshold` when interpreted as a percent of one base token
    ///      (`allowed = 10^decimals * dustThreshold / DUST_THRESHOLD_DENOMINATOR`).
    uint256 private constant DUST_THRESHOLD_DENOMINATOR = 100;

    /// @notice Emitted when a custodian proposes a balance update.
    event BalanceProposed(
        address balanceAccount,
        address proposer,
        uint256 newValue,
        uint256 nonce,
        uint64 proposedAt,
        bytes32 proposalHash
    );

    /// @notice Emitted when a custodian confirms a pending balance update.
    event BalanceConfirmed(
        address balanceAccount,
        address confirmer,
        uint256 oldValue,
        uint256 newValue,
        uint256 nonce
    );

    /// @notice Emitted when a new `proposeBalance` call overwrites an un-confirmed pending proposal.
    /// @dev The previous proposer's hash becomes permanently invalid; off-chain tooling that tracks
    ///      pending proposals MUST listen to this event to discard stale hashes.
    event ProposalOverwritten(
        address balanceAccount,
        address oldProposer,
        address newProposer,
        uint256 oldNonce,
        uint256 newNonce
    );

    /// @notice Emitted when the operation fuse adds or removes balance for an account.
    event BalanceChangedByFuse(address balanceAccount, int256 delta, uint256 newBalance);

    /// @notice Emitted after a batch of external actions has been executed.
    event ActionsExecuted(uint256 count);

    /// @notice Emitted by `syncSubstrates` for each balance account that is purged from the cache
    ///         because it has been revoked from the vault substrate set. The per-account mappings
    ///         (`balances`, `pendingProposals`, `lastUpdated`) are reset to zero alongside the cache
    ///         removal.
    /// @dev Off-chain monitoring SHOULD alert when this event fires unexpectedly — purges represent
    ///      a substrate-set reduction that operators must explicitly authorize via
    ///      `revokeMarketSubstrates(...)` on the vault. See `contracts/fuses/external_state/README.md`
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
    event AssetWithdrawn(address asset, uint256 amount);

    /// @notice Emitted when `sweepSurplus` moves tokens that did not arrive through the vault path
    ///         (donations) to the vault.
    /// @param asset Swept asset.
    /// @param amount Amount transferred to the vault (zero when there was no surplus).
    event SurplusSwept(address asset, uint256 amount);

    /// @notice Restricts access to the authorized PlasmaVault.
    modifier onlyVault() {
        if (msg.sender != VAULT) revert ExternalStateErrors.ExternalStateExecutorUnauthorizedVault();
        _;
    }

    /// @notice Restricts access to addresses currently present in the cached custodian list.
    /// @dev The check reads the `custodians[]` cache, not the vault substrate list. A custodian
    ///      revoked on the vault REMAINS authorized here until `syncSubstrates()` is called.
    ///      See the `custodians` storage docstring and README "Trust assumptions".
    modifier onlyCustodian() {
        if (!_isCustodian(msg.sender)) {
            revert ExternalStateErrors.ExternalStateExecutorUnauthorizedCustodian(msg.sender);
        }
        _;
    }

    /// @param marketId_ Market identifier bound to this executor (must be non-zero).
    /// @param vault_ Authorized PlasmaVault address (must be non-zero).
    constructor(uint256 marketId_, address vault_) {
        if (marketId_ == 0) revert ExternalStateErrors.ExternalStateExecutorZeroMarketId();
        if (vault_ == address(0)) revert ExternalStateErrors.ExternalStateExecutorZeroAddressConstructor();
        MARKET_ID = marketId_;
        VAULT = vault_;
    }

    // ============================================================
    // Vault-gated mutations
    // ============================================================

    /// @inheritdoc IExternalStateExecutor
    function addBalance(
        address balanceAccount_,
        uint256 valueInUnderlying_,
        address asset_,
        uint256 tokenAmount_
    ) external override onlyVault {
        int256 signedDelta = valueInUnderlying_.toInt256();
        balances[balanceAccount_] += valueInUnderlying_;
        unforwardedCredit[asset_] += tokenAmount_;
        emit BalanceChangedByFuse(balanceAccount_, signedDelta, balances[balanceAccount_]);
    }

    /// @inheritdoc IExternalStateExecutor
    function removeBalance(
        address balanceAccount_,
        uint256 valueInUnderlying_,
        address asset_,
        uint256 tokenAmount_
    ) external override onlyVault nonReentrant {
        uint256 current = balances[balanceAccount_];
        if (valueInUnderlying_ > current) {
            revert ExternalStateErrors.ExternalStateExitExceedsTrackedBalance(
                balanceAccount_,
                valueInUnderlying_,
                current
            );
        }
        int256 signedDelta = -valueInUnderlying_.toInt256();
        balances[balanceAccount_] = current - valueInUnderlying_;
        emit BalanceChangedByFuse(balanceAccount_, signedDelta, balances[balanceAccount_]);

        if (tokenAmount_ > 0) {
            _debitCredit(asset_, tokenAmount_);
            IERC20(asset_).safeTransfer(VAULT, tokenAmount_);
        }
    }

    /// @inheritdoc IExternalStateExecutor
    function execute(ExternalStateExecutorAction[] calldata actions_) external override onlyVault nonReentrant {
        // Settle `unforwardedCredit` with the balance change caused by the actions: tokens forwarded to an
        // external protocol reduce the credit, tokens returned to the executor increase it. Only cached
        // assets are settled (see `syncSubstrates`). The copy protects the loop from cache changes.
        address[] memory cachedAssets = assets;
        uint256 assetsLen = cachedAssets.length;
        uint256[] memory balancesBefore = new uint256[](assetsLen);
        for (uint256 i; i < assetsLen; ++i) {
            balancesBefore[i] = IERC20(cachedAssets[i]).balanceOf(address(this));
        }

        uint256 len = actions_.length;
        for (uint256 i; i < len; ++i) {
            Address.functionCall(actions_[i].target, actions_[i].data);
        }

        for (uint256 i; i < assetsLen; ++i) {
            uint256 balanceAfter = IERC20(cachedAssets[i]).balanceOf(address(this));
            if (balanceAfter < balancesBefore[i]) {
                _debitCredit(cachedAssets[i], balancesBefore[i] - balanceAfter);
            } else if (balanceAfter > balancesBefore[i]) {
                unforwardedCredit[cachedAssets[i]] += balanceAfter - balancesBefore[i];
            }
        }
        emit ActionsExecuted(len);
    }

    /// @inheritdoc IExternalStateExecutor
    function withdrawAssetBalance(address asset_) external override onlyVault {
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        if (bal > 0) {
            IERC20(asset_).safeTransfer(VAULT, bal);
        }
        // The whole balance left the executor, nothing is left to be forwarded.
        unforwardedCredit[asset_] = 0;
        emit AssetWithdrawn(asset_, bal);
    }

    /// @inheritdoc IExternalStateExecutor
    /// @dev Trust model: surplus is "everything not covered by `unforwardedCredit`", so tokens that return to the
    ///      executor outside a vault call (custody or protocol payouts sent straight to it) look like donations.
    ///      Such tokens are in NAV only while the last confirmed custodian report counts them.
    ///      Still counted (a custody or protocol payout sent straight to the executor before the next report): book them
    ///      with `exit`, while `unforwardedCredit(asset) == 0` (forward or exit credited tokens first: `removeBalance`
    ///      debits the credit by the exited amount, whatever its origin).
    ///      No longer counted (a donation, or a confirmed report that already excludes them): `sweepSurplus`, never `exit`
    ///      (an exit would remove the value a second time).
    ///      Custodians do not propose while `balanceOf(executor) > unforwardedCredit(asset)` for a cached asset unless they
    ///      know whether their report counts those tokens (the dust check does not block them). Monitoring: alert when
    ///      `balanceOf(executor) > unforwardedCredit(asset)`.
    ///      A counterparty that pulls tokens outside `execute` leaves the credit stale (above the token balance):
    ///      up to that amount, tokens that later reach the executor count in the dust check (a donation can block
    ///      custodians again) and `sweepSurplus` does not move them. Each `exit` or `execute` outflow consumes only
    ///      its own amount of the credit, so the block can return until outflows totalling the stale credit have run.
    function sweepSurplus(address asset_) external override onlyVault nonReentrant returns (uint256 amount) {
        uint256 bal = IERC20(asset_).balanceOf(address(this));
        // Tokens covered by `unforwardedCredit` are tracked by `balances[]` and stay; the rest never came
        // through the vault path, i.e. it is a donation. Neither `balances[]` nor the credit change.
        amount = bal - Math.min(unforwardedCredit[asset_], bal);
        if (amount > 0) {
            IERC20(asset_).safeTransfer(VAULT, amount);
        }
        emit SurplusSwept(asset_, amount);
    }

    // ============================================================
    // Custodian dual-approval
    // ============================================================

    /// @inheritdoc IExternalStateExecutor
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
        pendingProposals[balanceAccount_] = PendingProposal({
            value: newValue_,
            proposer: msg.sender,
            proposedAt: nowTs,
            nonce: newNonce
        });
        proposalBaseBalance[balanceAccount_] = balances[balanceAccount_];

        bytes32 h = _proposalHash(balanceAccount_, newValue_, msg.sender, nowTs, newNonce);
        emit BalanceProposed(balanceAccount_, msg.sender, newValue_, newNonce, nowTs, h);
    }

    /// @inheritdoc IExternalStateExecutor
    function confirmBalance(
        address balanceAccount_,
        bytes32 proposalHash_
    ) external override onlyCustodian nonReentrant {
        // 0. Authorization-first — validate `balanceAccount_` against the vault substrate set
        //    (source of truth). If the account has been revoked, reject before any further checks
        //    so off-chain monitoring sees a clean `ExternalStateUnsupportedSubstrate` signal.
        _requireBalanceAccountGrantedOnVault(balanceAccount_);
        // Defense-in-depth: also require the BA to be present in the local cache. Forces
        // `syncSubstrates()` to be called when the cache drifts behind the vault substrate set.
        _requireBalanceAccountInCache(balanceAccount_);

        PendingProposal memory pending = pendingProposals[balanceAccount_];
        // 1. no pending proposal
        if (pending.proposer == address(0)) {
            revert ExternalStateErrors.ExternalStateExecutorNoPendingProposal(balanceAccount_);
        }
        // 2. same proposer/confirmer
        if (pending.proposer == msg.sender) {
            revert ExternalStateErrors.ExternalStateExecutorSameProposerAndConfirmer(msg.sender);
        }
        // 3. TTL check (proposal expiration uses stalenessMax as TTL per plan)
        uint256 nowTs = block.timestamp;
        if (nowTs - pending.proposedAt > stalenessMax) {
            revert ExternalStateErrors.ExternalStateExecutorProposalExpired(pending.proposedAt, nowTs, stalenessMax);
        }
        // 4. dust check
        _checkDust();
        // 5. hash verification
        bytes32 expected = _proposalHash(
            balanceAccount_,
            pending.value,
            pending.proposer,
            pending.proposedAt,
            pending.nonce
        );
        if (expected != proposalHash_) {
            revert ExternalStateErrors.ExternalStateExecutorProposalHashMismatch(expected, proposalHash_);
        }
        // 5b. the account must not have been changed by an ALPHA flow since the proposal: the reported
        //     value is an absolute snapshot and would silently erase (or double count) that flow
        uint256 base = proposalBaseBalance[balanceAccount_];
        uint256 current = balances[balanceAccount_];
        if (current != base) {
            revert ExternalStateErrors.ExternalStateExecutorBalanceChangedSinceProposal(balanceAccount_, base, current);
        }
        // 6. MIN_UPDATE_INTERVAL (exempt first update where lastUpdated == 0)
        uint256 last = lastUpdated[balanceAccount_];
        if (last != 0 && nowTs - last < minUpdateInterval) {
            revert ExternalStateErrors.ExternalStateExecutorMinUpdateIntervalNotMet(last, nowTs, minUpdateInterval);
        }
        // 7. update balance + timestamps + monotonic confirm counter (circuit-breaker watermark)
        uint256 oldValue = current; // equals balances[balanceAccount_] (checked in 5b)
        balances[balanceAccount_] = pending.value;
        lastUpdated[balanceAccount_] = nowTs;
        lastCustodianUpdateTimestamp = nowTs;
        ++confirmCount;
        // 8. clear pending slot
        delete pendingProposals[balanceAccount_];
        // 9. emit
        emit BalanceConfirmed(balanceAccount_, msg.sender, oldValue, pending.value, pending.nonce);
    }

    // ============================================================
    // Substrate cache
    // ============================================================

    /// @inheritdoc IExternalStateExecutor
    function syncSubstrates() external override {
        _applySubstrates(IPlasmaVaultGovernance(VAULT).getMarketSubstrates(MARKET_ID));
    }

    /// @inheritdoc IExternalStateExecutor
    function setSubstrates(bytes32[] calldata substrates_) external override onlyVault {
        _applySubstrates(substrates_);
    }

    /// @dev Shared cache-rebuild logic for the pull (`syncSubstrates`) and push (`setSubstrates`)
    ///      paths. The push path exists because the vault's fallback rejects callbacks into the
    ///      vault while `PlasmaVault.execute` is running, so during in-execute bootstrap the fuse
    ///      reads the substrates from vault storage and pushes them here.
    function _applySubstrates(bytes32[] memory substrates) internal {
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
            ExternalStateSubstrateType t = ExternalStateSubstrateLib.decodeSubstrateType(sub);

            if (t == ExternalStateSubstrateType.ASSET) {
                address assetAddr = ExternalStateSubstrateLib.decodeAddressPayload(sub);
                // Dedupe: the vault accepts duplicate grants, but a duplicated cache entry would make `execute`
                // settle the same asset twice (an outflow of X would debit 2X). Skip, do not revert.
                bool known;
                uint256 assetsLen = assets.length;
                for (uint256 j; j < assetsLen; ++j) {
                    if (assets[j] == assetAddr) {
                        known = true;
                        break;
                    }
                }
                if (!known) {
                    assets.push(assetAddr);
                }
            } else if (t == ExternalStateSubstrateType.CUSTODIAN) {
                custodians.push(ExternalStateSubstrateLib.decodeAddressPayload(sub));
            } else if (t == ExternalStateSubstrateType.BALANCE_ACCOUNT) {
                address ba = ExternalStateSubstrateLib.decodeAddressPayload(sub);
                // Duplicate balance accounts in the substrate set always indicate a governance
                // misconfiguration — refuse to repopulate the cache instead of silently tolerating
                // them. O(n^2) cost is acceptable: `n` (number of BAs) is small (single digits in
                // practice) and `syncSubstrates` is a governance-frequency operation.
                uint256 baLen = balanceAccounts.length;
                for (uint256 j; j < baLen; ++j) {
                    if (balanceAccounts[j] == ba) {
                        revert ExternalStateErrors.ExternalStateDuplicateBalanceAccountSubstrate(ba);
                    }
                }
                balanceAccounts.push(ba);
            } else if (t == ExternalStateSubstrateType.STALENESS_MAX) {
                if (seenStaleness) {
                    revert ExternalStateErrors.ExternalStateDuplicateSingletonSubstrate(
                        uint8(ExternalStateSubstrateType.STALENESS_MAX)
                    );
                }
                seenStaleness = true;
                stalenessMax = ExternalStateSubstrateLib.decodeUint248Payload(sub);
            } else if (t == ExternalStateSubstrateType.BIG_CHANGE_BPS) {
                if (seenBigChange) {
                    revert ExternalStateErrors.ExternalStateDuplicateSingletonSubstrate(
                        uint8(ExternalStateSubstrateType.BIG_CHANGE_BPS)
                    );
                }
                seenBigChange = true;
                bigChangeBps = ExternalStateSubstrateLib.decodeUint248Payload(sub);
            } else if (t == ExternalStateSubstrateType.DUST_THRESHOLD) {
                if (seenDust) {
                    revert ExternalStateErrors.ExternalStateDuplicateSingletonSubstrate(
                        uint8(ExternalStateSubstrateType.DUST_THRESHOLD)
                    );
                }
                seenDust = true;
                dustThreshold = ExternalStateSubstrateLib.decodeUint248Payload(sub);
            } else if (t == ExternalStateSubstrateType.MIN_UPDATE_INTERVAL) {
                if (seenMinInterval) {
                    revert ExternalStateErrors.ExternalStateDuplicateSingletonSubstrate(
                        uint8(ExternalStateSubstrateType.MIN_UPDATE_INTERVAL)
                    );
                }
                seenMinInterval = true;
                minUpdateInterval = ExternalStateSubstrateLib.decodeUint248Payload(sub);
            } else if (t == ExternalStateSubstrateType.TARGET) {
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
            revert ExternalStateErrors.ExternalStateMandatorySingletonMissing(
                uint8(ExternalStateSubstrateType.STALENESS_MAX)
            );
        }
        if (bigChangeBps == 0) {
            revert ExternalStateErrors.ExternalStateMandatorySingletonMissing(
                uint8(ExternalStateSubstrateType.BIG_CHANGE_BPS)
            );
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

    /// @inheritdoc IExternalStateExecutor
    function getBalanceFuseSnapshot()
        external
        view
        override
        returns (uint256 totalBalance, uint256 bigChangeBps_, uint256 custodianConfirmCount_)
    {
        uint256 len = balanceAccounts.length;
        for (uint256 i; i < len; ++i) {
            totalBalance += balances[balanceAccounts[i]];
        }
        bigChangeBps_ = bigChangeBps;
        custodianConfirmCount_ = confirmCount;
    }

    /// @inheritdoc IExternalStateExecutor
    function getOldestUpdateTimestamp() external view override returns (uint256 oldest) {
        uint256 len = balanceAccounts.length;
        for (uint256 i; i < len; ++i) {
            uint256 ts = lastUpdated[balanceAccounts[i]];
            if (ts != 0 && (oldest == 0 || ts < oldest)) {
                oldest = ts;
            }
        }
    }

    /// @inheritdoc IExternalStateExecutor
    function balanceAccountsLength() external view override returns (uint256) {
        return balanceAccounts.length;
    }

    /// @inheritdoc IExternalStateExecutor
    function custodiansLength() external view override returns (uint256) {
        return custodians.length;
    }

    /// @inheritdoc IExternalStateExecutor
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
        revert ExternalStateErrors.ExternalStateExecutorBalanceAccountNotInCache(balanceAccount_);
    }

    /// @dev Revert if `balanceAccount_` is not currently granted as a BALANCE_ACCOUNT substrate
    ///      on the vault. Uses `IPlasmaVaultGovernance.isMarketSubstrateGranted` (external call)
    ///      — substrate state lives in the vault's storage, not the executor's, so we cannot
    ///      reuse the storage-reading helpers in `PlasmaVaultConfigLib`. Reverts with the same
    ///      `ExternalStateUnsupportedSubstrate` selector emitted by the fuse-side validation in
    ///      `ExternalStateOperationFuse._validateSubstratesAndActions` for off-chain log consistency.
    /// @param balanceAccount_ Address to validate against the vault substrate set.
    function _requireBalanceAccountGrantedOnVault(address balanceAccount_) internal view {
        bytes32 encoded = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount_);
        if (!IPlasmaVaultGovernance(VAULT).isMarketSubstrateGranted(MARKET_ID, encoded)) {
            revert ExternalStateErrors.ExternalStateUnsupportedSubstrate(
                uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT),
                encoded
            );
        }
    }

    /// @dev Decode only BALANCE_ACCOUNT substrates from `substrates_` into a tightly-sized memory
    ///      array. Two-pass scheme allocates exactly `count` slots in the first pass and fills
    ///      them in the second. Used by `syncSubstrates` to determine the new balance-account
    ///      set before storage replacement.
    /// @param substrates_ Substrate set returned by `getMarketSubstrates(MARKET_ID)`.
    /// @return newBAs Memory array of balance accounts referenced by the new substrate set.
    function _extractBalanceAccountsFromSubstrates(
        bytes32[] memory substrates_
    ) private pure returns (address[] memory newBAs) {
        uint256 len = substrates_.length;
        uint256 count;
        for (uint256 i; i < len; ++i) {
            if (
                ExternalStateSubstrateLib.decodeSubstrateType(substrates_[i]) ==
                ExternalStateSubstrateType.BALANCE_ACCOUNT
            ) {
                ++count;
            }
        }
        newBAs = new address[](count);
        uint256 idx;
        for (uint256 i; i < len; ++i) {
            bytes32 sub = substrates_[i];
            if (ExternalStateSubstrateLib.decodeSubstrateType(sub) == ExternalStateSubstrateType.BALANCE_ACCOUNT) {
                newBAs[idx++] = ExternalStateSubstrateLib.decodeAddressPayload(sub);
            }
        }
    }

    /// @dev For every balance account present in `oldBAs_` but absent from `newBAs_`, enforce
    ///      that `balances[oldBA] == 0` and clear the per-account mappings (`balances`,
    ///      `pendingProposals`, `lastUpdated`). Reverts on the first violation with
    ///      `ExternalStateExecutorBalanceAccountStillFunded`. Emits `BalanceAccountPurged(oldBA)` for each
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
                    revert ExternalStateErrors.ExternalStateExecutorBalanceAccountStillFunded(oldBA, residual);
                }
                delete balances[oldBA];
                delete pendingProposals[oldBA];
                delete lastUpdated[oldBA];
                emit BalanceAccountPurged(oldBA);
            }
        }
    }

    /// @dev Reduces `unforwardedCredit[asset_]` by `amount_`, clamped at zero. The clamp absorbs rounding of
    ///      fee-on-transfer tokens, tokens spent that were not credited (e.g. a donation spent by an action)
    ///      and assets that were not yet cached when the credit was created.
    function _debitCredit(address asset_, uint256 amount_) private {
        unforwardedCredit[asset_] -= Math.min(unforwardedCredit[asset_], amount_);
    }

    /// @notice Verifies that no cached asset has credited-but-unforwarded tokens above the dust allowance.
    /// @dev Dust check: for each cached asset, the amount that was credited to balance accounts through the
    ///      vault path and still sits on the executor (`unforwardedCredit`, clamped to the actual token
    ///      balance) must be less than or equal to `dustThreshold * 10^decimals / 100` (i.e. `dustThreshold`
    ///      percent of one base token). If `dustThreshold == 0`, no such amount is allowed. The raw token
    ///      balance is deliberately NOT used: anyone can transfer tokens to the executor, which would block
    ///      custodians and, after `stalenessMax`, freeze the vault (IL-8739). Donated tokens are not in
    ///      `balances[]`, so a custodian report cannot overwrite them. Reverts with
    ///      `ExternalStateExecutorDustCheckFailed` if any asset exceeds the allowance. Only cached assets
    ///      (from `syncSubstrates`) are checked, so newly-added ASSET substrates require a `syncSubstrates`
    ///      call to participate.
    function _checkDust() internal view {
        uint256 len = assets.length;
        uint256 dt = dustThreshold;
        for (uint256 i; i < len; ++i) {
            address asset = assets[i];
            uint256 bal = Math.min(unforwardedCredit[asset], IERC20(asset).balanceOf(address(this)));
            uint256 allowed = ((10 ** IERC20Metadata(asset).decimals()) * dt) / DUST_THRESHOLD_DENOMINATOR;
            if (bal > allowed) {
                revert ExternalStateErrors.ExternalStateExecutorDustCheckFailed(asset, bal, allowed);
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
        return
            keccak256(
                abi.encode(address(this), block.chainid, balanceAccount_, value_, proposer_, proposedAt_, nonce_)
            );
    }
}
