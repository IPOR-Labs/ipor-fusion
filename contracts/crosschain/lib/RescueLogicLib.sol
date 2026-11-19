// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {CrosschainConstants} from "./CrosschainConstants.sol";
import {CrosschainErrors} from "./CrosschainErrors.sol";

/// @dev Mutable rescue state shared with `RescueModule`. Keeping it in one struct lets the sizeable
/// queue/timelock state machine live in this linked library instead of being duplicated in every
/// executor, dispatcher and factory runtime.
struct RescueStorage {
    uint256 guardianVetoEpoch;
    uint256 rescueCount;
    uint256 pendingRescueCount;
    mapping(uint256 rescueId => RescueStorageRecord record) rescues;
}

struct RescueStorageRecord {
    uint8 kind;
    uint8 state;
    uint64 executableAt;
    uint64 vetoEpoch;
    address target;
    uint256 value;
    bytes32 commitment;
}

library RescueLogicLib {
    using SafeCast for uint256;

    uint8 private constant _KIND_GENERIC = 1;
    uint8 private constant _KIND_FORCE_RESOLVE = 2;
    uint8 private constant _STATE_SCHEDULED = 1;
    uint8 private constant _STATE_EXECUTED = 2;
    uint8 private constant _STATE_CANCELLED = 3;

    /// @dev `bytes4(keccak256("transfer(address,uint256)"))` — the only shape allowed against a
    ///      caller's protected (tracked) asset.
    bytes4 private constant _ERC20_TRANSFER_SELECTOR = 0xa9059cbb;
    /// @dev `runWithContext((address[],bytes[]))` of the Fusion ContextManager (IL-8770); pinned by tests.
    bytes4 private constant _RUN_WITH_CONTEXT_SELECTOR = 0x6955cebb;
    /// @dev `approve(address,uint256)`. A host that holds vault shares accepts it only with amount 0 (IL-9654).
    bytes4 private constant _ERC20_APPROVE_SELECTOR = 0x095ea7b3;
    /// @dev ERC-4626 `redeem(uint256,address,address)`. A host that holds vault shares accepts it only with
    ///      itself as the owner (IL-9654).
    bytes4 private constant _ERC4626_REDEEM_SELECTOR = 0xba087652;
    /// @dev PlasmaVault `redeemFromRequest(uint256,address,address)`. A host that holds vault shares accepts it only
    ///      with itself as the owner (IL-9654).
    bytes4 private constant _REDEEM_FROM_REQUEST_SELECTOR = 0xa64099d2;
    /// @dev WithdrawManager `requestShares(uint256)`. A host that holds vault shares accepts it only on a manager
    ///      whose vault is neither tracked nor allowlisted, checked at schedule and again at execute (IL-9654).
    bytes4 private constant _REQUEST_SHARES_SELECTOR = 0xfc415e9c;
    /// @dev WithdrawManager `getPlasmaVaultAddress()`: the one read the `requestShares` rule makes on the target.
    bytes4 private constant _GET_PLASMA_VAULT_ADDRESS_SELECTOR = 0x0bdcc726;

    /// @dev LayerZero EndpointV2 packet-hygiene selectors, the only calls a rescue may make to the host's
    ///      `endpoint()` (IL-8555). Each only touches the inbound channel of a (srcEid, sender, nonce) tuple:
    ///      `skip(address,uint32,bytes32,uint64)`.
    bytes4 private constant _LZ_SKIP_SELECTOR = 0xd70b8902;
    /// @dev `clear(address,(uint32,bytes32,uint64),bytes32,bytes)`.
    bytes4 private constant _LZ_CLEAR_SELECTOR = 0x2a56c1b0;
    /// @dev `nilify(address,uint32,bytes32,uint64,bytes32)`.
    bytes4 private constant _LZ_NILIFY_SELECTOR = 0x2e80fbf3;
    /// @dev `burn(address,uint32,bytes32,uint64,bytes32)`.
    bytes4 private constant _LZ_BURN_SELECTOR = 0x40f80683;

    event RescueScheduled(
        uint256 rescueId,
        address target,
        uint256 value,
        bytes32 commitment,
        uint256 executableAt,
        uint256 vetoEpoch
    );
    event RescueExecuted(uint256 rescueId, address target, uint256 value, bytes32 commitment);
    event RescueCancelled(uint256 rescueId, address canceller);
    event AllRescuesVetoed(uint256 newVetoEpoch);
    event ForceResolveScheduled(uint256 rescueId, bytes32 commitment, uint256 executableAt, uint256 vetoEpoch);
    event ForceResolveConsumed(uint256 rescueId, bytes32 commitment);

    /// @dev Six fences bound what a generic rescue may AUTHORISE or ORIGINATE, all checked at schedule
    ///      time (`target` and `keccak256(callData)` are committed): the caller's factory is untouchable
    ///      (IL-8261), calls to its `ASSET()` narrow to `transfer` (audit
    ///      `tracked_ledger_rescue_invariant_bypassable_via_approval`), calls to its transport
    ///      (CCIP router / Stargate pool / LayerZero endpoint) are banned except LayerZero inbound packet
    ///      hygiene (IL-8555), and calls to any tracked or allowlisted vault are banned (IL-8556). The
    ///      vault fence is repeated in `execute`, because the tracked set can change during the timelock.
    ///      Two more: the caller's own executors are untouchable (IL-8763, Stargate factory host; re-checked in
    ///      `execute` because a CREATE3 executor address can gain code during the delay), and no call may carry the
    ///      ContextManager `runWithContext` selector (IL-8770), because it would make the host the context sender.
    ///      One more, after all of the above and only on hosts that hold vault shares (dispatchers: the host answers
    ///      `getTrackedVaults()` or `trackedVaultsLength()`): the calldata must have one of seven shapes, otherwise
    ///      `RescueCallShapeNotAllowed` (IL-9654, see `_requireAllowedRescueShape`). Its `requestShares` rule reads
    ///      the target manager's vault and is repeated in `execute`. The fences above keep their order and errors.
    function schedule(
        RescueStorage storage self,
        uint256 rescueDelay_,
        address target_,
        uint256 value_,
        bytes calldata callData_
    ) public returns (uint256 rescueId) {
        _requireQueueCapacity(self);
        _requireNotFactoryTarget(target_);
        _requireNotOwnExecutorTarget(target_); // IL-8763
        _requireNotTransportTarget(target_, callData_);
        _requireNotContextCall(target_, callData_); // IL-8770
        {
            (address[] memory tracked, bool shareHost) = _trackedVaults();
            address[] memory banned = _bannedVaultTargets(tracked);
            _requireNotTrackedVaultTarget(target_, banned);
            _requireSafeProtectedTokenCall(target_, callData_);
            if (shareHost) _requireAllowedRescueShape(target_, callData_, banned); // IL-9654
        }
        bytes32 commitment = keccak256(callData_);
        uint64 executableAt = (block.timestamp + rescueDelay_).toUint64();
        uint64 epoch = self.guardianVetoEpoch.toUint64();
        rescueId = ++self.rescueCount;
        self.rescues[rescueId] = RescueStorageRecord({
            kind: _KIND_GENERIC,
            state: _STATE_SCHEDULED,
            executableAt: executableAt,
            vetoEpoch: epoch,
            target: target_,
            value: value_,
            commitment: commitment
        });
        unchecked {
            ++self.pendingRescueCount;
        }
        emit RescueScheduled(rescueId, target_, value_, commitment, executableAt, epoch);
    }

    /// @dev Re-checks the vault ban against the CURRENT tracked set plus the allowlist (UPDATE_VAULTS can add
    ///      a vault between schedule and execute) and snapshots every tracked vault's share balance around the
    ///      call: any decrease reverts `RescueTrackedSharesReduced`. The snapshot bounds what a rescue may
    ///      MOVE in shares (an indirect target holding a leftover allowance), while the target ban and the
    ///      schedule-time shape fence (IL-9654) narrow the calls it may make (an allowance grant leaves the balance
    ///      unchanged, so the snapshot does not see it) — the same pair the host's ASSET floor and
    ///      `_requireSafeProtectedTokenCall` form for the asset. The shape itself is not re-checked (the calldata is
    ///      bound by its hash); only the state-dependent `requestShares` rule is: on a host that holds vault shares,
    ///      the manager's vault is read again and must still be neither tracked nor allowlisted, otherwise
    ///      `RescueTrackedVaultCall(vault)`, or `RescueCallShapeNotAllowed` when the manager no longer answers with one
    ///      non-zero address (IL-9654). Hosts without a tracked set (executors) skip all of these.
    function execute(RescueStorage storage self, uint256 rescueId_, bytes calldata callData_) public {
        RescueStorageRecord storage record = self.rescues[rescueId_];
        if (record.kind != _KIND_GENERIC) revert CrosschainErrors.RescueWrongKind(rescueId_);
        _requireExecutable(self, rescueId_, record);
        if (keccak256(callData_) != record.commitment) revert CrosschainErrors.RescueCalldataMismatch(rescueId_);

        record.state = _STATE_EXECUTED;
        unchecked {
            --self.pendingRescueCount;
        }

        address target = record.target;
        uint256 value = record.value;
        bytes32 commitment = record.commitment;
        _requireNotOwnExecutorTarget(target); // IL-8763
        address[] memory vaults;
        {
            bool shareHost;
            (vaults, shareHost) = _trackedVaults();
            address[] memory banned = _bannedVaultTargets(vaults);
            _requireNotTrackedVaultTarget(target, banned);
            if (shareHost && callData_.length == 36 && bytes4(callData_[:4]) == _REQUEST_SHARES_SELECTOR) {
                _requireRequestVaultNotBanned(target, banned); // IL-9654
            }
        }
        uint256[] memory sharesBefore = _shareBalances(vaults);
        (bool ok, bytes memory ret) = target.call{value: value}(callData_);
        if (!ok) {
            if (ret.length > 0) {
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
            revert CrosschainErrors.RescueCallFailed();
        }
        _requireSharesNotReduced(vaults, sharesBefore);
        emit RescueExecuted(rescueId_, target, value, commitment);
    }

    function cancel(RescueStorage storage self, uint256 rescueId_, address canceller_) public {
        RescueStorageRecord storage record = self.rescues[rescueId_];
        if (record.state != _STATE_SCHEDULED) revert CrosschainErrors.RescueNotScheduled(rescueId_);
        record.state = _STATE_CANCELLED;
        if (record.vetoEpoch == self.guardianVetoEpoch && self.pendingRescueCount > 0) {
            unchecked {
                --self.pendingRescueCount;
            }
        }
        emit RescueCancelled(rescueId_, canceller_);
    }

    function vetoAll(RescueStorage storage self) public {
        uint256 newEpoch;
        unchecked {
            newEpoch = ++self.guardianVetoEpoch;
        }
        self.pendingRescueCount = 0;
        emit AllRescuesVetoed(newEpoch);
    }

    function scheduleForce(
        RescueStorage storage self,
        uint256 rescueDelay_,
        bytes32 commitment_
    ) public returns (uint256 rescueId) {
        _requireQueueCapacity(self);
        uint64 executableAt = (block.timestamp + rescueDelay_).toUint64();
        uint64 epoch = self.guardianVetoEpoch.toUint64();
        rescueId = ++self.rescueCount;
        self.rescues[rescueId] = RescueStorageRecord({
            kind: _KIND_FORCE_RESOLVE,
            state: _STATE_SCHEDULED,
            executableAt: executableAt,
            vetoEpoch: epoch,
            target: address(0),
            value: 0,
            commitment: commitment_
        });
        unchecked {
            ++self.pendingRescueCount;
        }
        emit ForceResolveScheduled(rescueId, commitment_, executableAt, epoch);
    }

    function consumeForce(RescueStorage storage self, uint256 rescueId_, bytes32 commitment_) public {
        RescueStorageRecord storage record = self.rescues[rescueId_];
        if (record.kind != _KIND_FORCE_RESOLVE) revert CrosschainErrors.RescueWrongKind(rescueId_);
        _requireExecutable(self, rescueId_, record);
        if (record.commitment != commitment_) revert CrosschainErrors.ForceResolveCommitmentMismatch(rescueId_);
        record.state = _STATE_EXECUTED;
        unchecked {
            --self.pendingRescueCount;
        }
        emit ForceResolveConsumed(rescueId_, commitment_);
    }

    /// @dev A post-call balance snapshot (the `_afterRescueExecuted` hook) cannot enforce "rescue may
    ///      take untracked surplus only": `approve`/`permit`/operator grants hand out spending rights
    ///      over tracked value while leaving the balance unchanged, so the hook passes and the tracked
    ///      tokens are pulled afterwards outside the timelock and the guardian's veto window. Only the
    ///      asset itself can grant rights over the caller's own balance, so narrowing calls to it to a
    ///      plain `transfer(address,uint256)` closes every such shape while keeping surplus sweeps —
    ///      which the balance snapshot does bound — available. Checked at schedule time; `target` and
    ///      `keccak256(callData)` are committed there, so execution cannot deviate.
    function _requireSafeProtectedTokenCall(address target_, bytes calldata callData_) private view {
        address protectedToken = _selfAddressGetter("ASSET()");
        if (protectedToken == address(0) || target_ != protectedToken) return;
        // `transfer(address,uint256)`; the length check rejects trailing-argument smuggling.
        bytes4 selector = callData_.length < 4 ? bytes4(0) : bytes4(callData_[:4]);
        if (selector != _ERC20_TRANSFER_SELECTOR || callData_.length != 68) {
            revert CrosschainErrors.RescueProtectedTokenCall(protectedToken, selector);
        }
    }

    /// @dev A rescue executes with the caller as `msg.sender`, and the factory authenticates its executor by
    ///      `msg.sender` alone. On Stargate, a rescue call to `requestDispatcher` sends a ticket the executor
    ///      holds no request record for, with rescue roles of the admin's choosing: its ACK and its TTL
    ///      cancel both revert in the executor callback, and the dispatcher it deploys blocks every later
    ///      ticket for that (executor, chain) pair with `TicketAdoptionCommitmentMismatch` (IL-8261). No
    ///      factory call is a rescue, so every call to the caller's own factory is rejected. Checked at
    ///      schedule time; `target` is committed there, so execution cannot deviate.
    function _requireNotFactoryTarget(address target_) private view {
        address factory = _selfAddressGetter("FACTORY()");
        if (factory != address(0) && target_ == factory) revert CrosschainErrors.RescueFactoryCall(factory);
    }

    /// @dev Executor fence (IL-8763). The Stargate factory hosts this module and authenticates nothing
    ///      but `msg.sender` on its executors' `onDispatcherCreated` / `onDispatcherRequestFailed` /
    ///      `onDispatcherRequestCancelled` callbacks, so a rescue call from the factory to one of its own
    ///      executors would forge a dispatcher ACK / NACK. No such call is a rescue (ACK is retried by
    ///      LayerZero, cancel has `cancelPendingDeployment`, native funds have `sweepNative`), so every call
    ///      to an address the host reports through `isExecutor(address)` is rejected, for any selector and
    ///      value. Hosts without `isExecutor` make the staticcall fail, which is a no-op. Re-checked in
    ///      `execute`: the CREATE3 executor address can be scheduled before it has code.
    function _requireNotOwnExecutorTarget(address target_) private view {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature("isExecutor(address)", target_));
        if (ok && ret.length == 32 && abi.decode(ret, (bool))) revert CrosschainErrors.RescueExecutorCall(target_);
    }

    /// @dev Context fence (IL-8770). `ContextManager.runWithContext` has no role and sets the context sender to
    ///      its `msg.sender`, so a rescue call to it makes the host the sender of any approved-target call
    ///      (e.g. a vault `approve(ADMIN, max)` over the host's shares, which neither the vault ban nor the
    ///      share snapshot sees). No rescue needs it, so the selector is rejected on every target. Checked at
    ///      schedule time; `keccak256(callData)` is committed there.
    function _requireNotContextCall(address target_, bytes calldata callData_) private pure {
        if (callData_.length >= 4 && bytes4(callData_[:4]) == _RUN_WITH_CONTEXT_SELECTOR) {
            revert CrosschainErrors.RescueContextCall(target_);
        }
    }

    /// @dev Transport fence (IL-8555). The LayerZero endpoint and the CCIP router authenticate the host by
    ///      bare `msg.sender`, and executor and dispatcher are same-address CREATE3 twins, so a rescue
    ///      `endpoint.send(...)` / `router.ccipSend(...)` would forge a peer-authenticated protocol message
    ///      (e.g. UPDATE_VAULTS + DEPOSIT to an attacker vault) and move value on the OTHER chain, where no
    ///      floor runs and no ASSET leaves the host. So: no CCIP router call is a rescue; on the LayerZero
    ///      endpoint only inbound packet hygiene (`skip`, `clear`, `nilify`, `burn`) is allowed. Everything
    ///      else (`send`, `setDelegate`, `setConfig`, `setSendLibrary`, `setReceiveLibrary*`, `lzReceive`,
    ///      ...) is rejected, so a rescue can no longer reach the endpoint's config setters (IL-8538 family;
    ///      `setDelegate` is also disabled on the hosts, IL-8557 / IL-8558). The Stargate pool
    ///      (`STARGATE_POOL()`) is banned for ANY call: `lzCompose` accepts a compose whose `composeFrom` is
    ///      the host, i.e. the address that called `pool.sendToken`, so a rescue `sendToken` with a compose
    ///      payload would forge a peer-authenticated delivery on the twin (a zero/dust amount could pre-set
    ///      `transferSettled[predictableId]` and strand the real transfer). A host without a getter returns
    ///      `address(0)` and that check does not apply.
    function _requireNotTransportTarget(address target_, bytes calldata callData_) private view {
        address router = _selfAddressGetter("CCIP_ROUTER()");
        bytes4 selector = callData_.length < 4 ? bytes4(0) : bytes4(callData_[:4]);
        if (router != address(0) && target_ == router) {
            revert CrosschainErrors.RescueTransportCall(router, selector);
        }
        address pool = _selfAddressGetter("STARGATE_POOL()");
        if (pool != address(0) && target_ == pool) revert CrosschainErrors.RescueTransportCall(pool, selector);
        address endpoint = _selfAddressGetter("endpoint()");
        if (endpoint != address(0) && target_ == endpoint) {
            if (!_isLzHygieneSelector(selector)) revert CrosschainErrors.RescueTransportCall(endpoint, selector);
        }
    }

    function _isLzHygieneSelector(bytes4 selector_) private pure returns (bool) {
        return
            selector_ == _LZ_SKIP_SELECTOR ||
            selector_ == _LZ_CLEAR_SELECTOR ||
            selector_ == _LZ_NILIFY_SELECTOR ||
            selector_ == _LZ_BURN_SELECTOR;
    }

    /// @dev Shape fence (IL-9654) for hosts that hold vault shares (dispatchers). The fences above name targets, but
    ///      the contracts that can act for a share holder cannot be listed: a vault connector (Euler EVC
    ///      `setAccountOperator` / `call`), a lending sibling of a vault (`borrow` against the holder's shares), a
    ///      trusted forwarder, or the share token of a vault that is not allowlisted (`approve`). Such a call can
    ///      grant a right over the host's shares, or encumber them, without a call to a tracked vault and without a
    ///      balance change, so neither the vault ban nor the share snapshot sees it. A host that answers
    ///      `getTrackedVaults()` or `trackedVaultsLength()` therefore accepts a generic rescue only in one of seven
    ///      calldata shapes:
    ///      - empty calldata: value only; on a contract target it runs that contract's `receive` / `fallback` with
    ///        the host as `msg.sender`, and this fence does not judge what that code does;
    ///      - `transfer(address,uint256)`, exactly 68 bytes;
    ///      - `approve(address,uint256)` with amount 0, exactly 68 bytes;
    ///      - `redeem(uint256,address,address)`, exactly 100 bytes, with the whole 32-byte owner word equal to the
    ///        host;
    ///      - `redeemFromRequest(uint256,address,address)`, exactly 100 bytes, with the whole 32-byte owner word
    ///        equal to the host;
    ///      - `requestShares(uint256)`, exactly 36 bytes, on a WithdrawManager whose vault is neither tracked nor
    ///        allowlisted (`_requireRequestVaultNotBanned`; repeated in `execute`);
    ///      - LayerZero inbound packet hygiene (`skip`, `clear`, `nilify`, `burn`) on the host's own `endpoint()`.
    ///      Any other call reverts `RescueCallShapeNotAllowed(target, selector)` at schedule time. The forwarded
    ///      value and the recipient of `transfer`, `redeem` and `redeemFromRequest` are not restricted.
    ///      What this guarantees is narrow: the fence checks the bytes of the call, not what the target does with
    ///      them. For ERC-20 tokens and ERC-4626 / PlasmaVault vaults these shapes move only the host's own balance
    ///      at the direct target or set an allowance to zero, and on a WithdrawManager `requestShares` files a
    ///      request over the host's own shares; a target that gives one of these selectors another meaning is not
    ///      covered (an ERC-721 `approve(spender, 0)` approves token id 0). NFTs are not supported on crosschain
    ///      hosts. The manager's request fee is not bounded on this path: the `REQUEST_SHARES` command caps it with
    ///      `maxFeeShares`, a `requestShares` rescue pays whatever fee the manager charges when it executes, and
    ///      that fee is taken from the host's shares.
    ///      The rule depends on the host's code, not on the content of its tracked set, so it also holds while the
    ///      sets are empty and after a removal. Hosts without a tracked-vault set (executors, the Stargate factory)
    ///      are not restricted. On dispatchers linked with this library it refuses at schedule the rescue routes
    ///      through a vault connector (IL-9654), through a lending sibling (IL-9672) and a share `approve` above 0
    ///      while a vault is off the allowlist (IL-8844), which were documentation-only before (IL-9590 D-076).
    function _requireAllowedRescueShape(
        address target_,
        bytes calldata callData_,
        address[] memory banned_
    ) private view {
        uint256 length = callData_.length;
        if (length == 0) return;
        bytes4 selector = length < 4 ? bytes4(0) : bytes4(callData_[:4]);
        if (length == 68) {
            if (selector == _ERC20_TRANSFER_SELECTOR) return;
            if (selector == _ERC20_APPROVE_SELECTOR && uint256(bytes32(callData_[36:68])) == 0) return;
        } else if (length == 100) {
            if (
                (selector == _ERC4626_REDEEM_SELECTOR || selector == _REDEEM_FROM_REQUEST_SELECTOR) &&
                bytes32(callData_[68:100]) == bytes32(uint256(uint160(address(this))))
            ) return;
        } else if (length == 36 && selector == _REQUEST_SHARES_SELECTOR) {
            _requireRequestVaultNotBanned(target_, banned_);
            return;
        }
        if (_isLzHygieneSelector(selector)) {
            address endpoint = _selfAddressGetter("endpoint()");
            if (endpoint != address(0) && target_ == endpoint) return;
        }
        revert CrosschainErrors.RescueCallShapeNotAllowed(target_, selector);
    }

    /// @dev `requestShares` rule (IL-9654), at schedule (inside the shape fence) and again in `execute` against the
    ///      current sets. One read, fail-closed: the target must answer `getPlasmaVaultAddress()` with exactly one
    ///      32-byte word holding a non-zero address (the word is decoded as `uint256`, so dirty upper bits refuse
    ///      instead of failing in the decoder). A failed call, a target without code, any other return length, zero
    ///      or dirty upper bits revert `RescueCallShapeNotAllowed(target, requestShares selector)`. The vault it
    ///      reports must not be in the ban set the vault fence uses (tracked, plus allowlisted on Stargate),
    ///      otherwise `RescueTrackedVaultCall(vault)`. The rule goes from manager to vault only: it trusts the vault
    ///      the manager reports and does not check that the vault still uses this manager. The manager's request fee
    ///      is not read or bounded.
    function _requireRequestVaultNotBanned(address manager_, address[] memory banned_) private view {
        (bool ok, bytes memory ret) = manager_.staticcall(abi.encodeWithSelector(_GET_PLASMA_VAULT_ADDRESS_SELECTOR));
        uint256 word = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
        if (word == 0 || word > type(uint160).max) {
            revert CrosschainErrors.RescueCallShapeNotAllowed(manager_, _REQUEST_SHARES_SELECTOR);
        }
        // casting to 'uint160' is safe because `word <= type(uint160).max` is checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        _requireNotTrackedVaultTarget(address(uint160(word)), banned_);
    }

    /// @dev Tracked-vault fence (IL-8556). The ERC-4626 shares a dispatcher holds for its tracked vaults are
    ///      in NAV but are neither the ASSET (so the host floor does not see them) nor narrowed:
    ///      `approve(x, max)` on a share token survives the timelock and `redeem(S, x, this)` drains the
    ///      position. No call to a tracked OR allowlisted vault is a rescue: the Stargate dispatcher keeps its deposit
    ///      allowlist apart from the tracked set (which grows on the first deposit), so an approval granted on an
    ///      allowlisted-but-untracked vault would otherwise survive until shares exist. The `requestShares` rule
    ///      (IL-9654) reuses it for the vault the target manager reports, so the error then names that vault.
    function _requireNotTrackedVaultTarget(address target_, address[] memory vaults_) private pure {
        for (uint256 i; i < vaults_.length; ++i) {
            if (vaults_[i] == target_) revert CrosschainErrors.RescueTrackedVaultCall(target_);
        }
    }

    /// @dev Target ban set = tracked vaults UNION the host's deposit allowlist (`getAllowedVaults()`, Stargate
    ///      dispatcher only; executors and the CCIP dispatcher lack it, which is a no-op). The share SNAPSHOT
    ///      stays on the tracked set alone (an untracked vault holds no shares). The `requestShares` rule checks
    ///      the vault a manager reports against this same set. A vault that is not allowlisted (before it is ever
    ///      allowlisted, or after a removal with a residual, IL-8784) is outside this ban; on a host that holds vault
    ///      shares the shape fence (`_requireAllowedRescueShape`, IL-9654) refuses an `approve` above 0 on every
    ///      target, so a rescue can no longer leave an allowance on it that would survive a later re-allowlisting
    ///      (IL-8844). On dispatchers linked with this library that replaces the documentation-only treatment of
    ///      IL-8844, IL-9654 and IL-9672 (IL-9590 D-076).
    function _bannedVaultTargets(address[] memory tracked_) private view returns (address[] memory banned) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature("getAllowedVaults()"));
        if (!ok || ret.length < 64) return tracked_;
        address[] memory allowed = abi.decode(ret, (address[]));
        banned = new address[](tracked_.length + allowed.length);
        for (uint256 i; i < tracked_.length; ++i) {
            banned[i] = tracked_[i];
        }
        for (uint256 i; i < allowed.length; ++i) {
            banned[tracked_.length + i] = allowed[i];
        }
    }

    /// @dev The host's tracked vault set, read through staticcalls so the hosts need no new code. Stargate
    ///      dispatcher: `getTrackedVaults()`. CCIP dispatcher: `trackedVaultsLength()` +
    ///      `trackedVaults(uint256)`, bounded by `MAX_TRACKED_POSITION_VAULTS`. `shareHost` is true when either
    ///      read answers (an array from `getTrackedVaults()`, one word from `trackedVaultsLength()`), also for an
    ///      empty set; it selects the IL-9654 shape fence and `requestShares` rule. A host exposing neither
    ///      (executors, the Stargate factory) yields an empty list and `shareHost == false`, so the tracked-vault
    ///      fences do not apply.
    function _trackedVaults() private view returns (address[] memory vaults, bool shareHost) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature("getTrackedVaults()"));
        if (ok && ret.length >= 64) {
            vaults = abi.decode(ret, (address[]));
            _requireTrackedSetWithinCap(vaults.length);
            return (vaults, true);
        }
        (ok, ret) = address(this).staticcall(abi.encodeWithSignature("trackedVaultsLength()"));
        if (!ok || ret.length != 32) return (new address[](0), false);
        shareHost = true;
        uint256 len = abi.decode(ret, (uint256));
        _requireTrackedSetWithinCap(len);
        vaults = new address[](len);
        for (uint256 i; i < len; ++i) {
            (ok, ret) = address(this).staticcall(abi.encodeWithSignature("trackedVaults(uint256)", i));
            if (!ok || ret.length != 32) {
                revert CrosschainErrors.RescueHostReadFailed(bytes4(keccak256("trackedVaults(uint256)")));
            }
            vaults[i] = abi.decode(ret, (address));
        }
    }

    function _requireTrackedSetWithinCap(uint256 len_) private pure {
        if (len_ > CrosschainConstants.MAX_TRACKED_POSITION_VAULTS) {
            revert CrosschainErrors.RescueTrackedSetTooLarge(len_, CrosschainConstants.MAX_TRACKED_POSITION_VAULTS);
        }
    }

    function _shareBalances(address[] memory vaults_) private view returns (uint256[] memory balances) {
        balances = new uint256[](vaults_.length);
        for (uint256 i; i < vaults_.length; ++i) {
            balances[i] = IERC20(vaults_[i]).balanceOf(address(this));
        }
    }

    function _requireSharesNotReduced(address[] memory vaults_, uint256[] memory before_) private view {
        for (uint256 i; i < vaults_.length; ++i) {
            uint256 afterBalance = IERC20(vaults_[i]).balanceOf(address(this));
            if (afterBalance < before_[i]) {
                revert CrosschainErrors.RescueTrackedSharesReduced(vaults_[i], before_[i], afterBalance);
            }
        }
    }

    /// @dev Reads an address getter of the caller (e.g. its tracked `ASSET()` or its `FACTORY()`). Public
    ///      library functions run under `delegatecall`, so `address(this)` is the executor/dispatcher
    ///      itself. Reading it here instead of taking it as an argument keeps the guards off the callers'
    ///      runtime, which sits within tens of bytes of the EIP-170 limit. A caller without the getter
    ///      returns `address(0)`, and the guard that asked for it does not apply.
    function _selfAddressGetter(string memory signature_) private view returns (address value) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature(signature_));
        if (!ok || ret.length != 32) return address(0);
        return abi.decode(ret, (address));
    }

    function _requireQueueCapacity(RescueStorage storage self) private view {
        if (self.pendingRescueCount >= CrosschainConstants.MAX_PENDING_RESCUES) {
            revert CrosschainErrors.RescueQueueFull(CrosschainConstants.MAX_PENDING_RESCUES);
        }
    }

    function _requireExecutable(
        RescueStorage storage self,
        uint256 rescueId_,
        RescueStorageRecord storage record_
    ) private view {
        if (record_.state == _STATE_EXECUTED) revert CrosschainErrors.RescueAlreadyConsumed(rescueId_);
        if (record_.state != _STATE_SCHEDULED) revert CrosschainErrors.RescueNotScheduled(rescueId_);
        if (block.timestamp < record_.executableAt) {
            revert CrosschainErrors.RescueTimelockNotElapsed(rescueId_, block.timestamp, record_.executableAt);
        }
        if (record_.vetoEpoch != self.guardianVetoEpoch) revert CrosschainErrors.RescueVetoed(rescueId_);
    }
}
