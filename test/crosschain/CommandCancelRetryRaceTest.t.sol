// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title CommandCancelRetryRaceTest
/// @notice Regression cover for `config_epoch_desync_via_retry_clearing_in_flight_cancel`.
/// @dev Drives a REAL executor against a REAL dispatcher with hand-relayed payloads
///      (see `StargateTwoSidedBase`), so the delivery ORDER of a CANCEL and a RETRY can be chosen.
///
///      The bug: `buildCancel` set `awaitingCancel` while leaving the command FAILED, so `buildRetry` was
///      still callable and cleared the flag. With the natural ordering (CANCEL sent first, delivered
///      first) the dispatcher resolved the command as CANCELLED WITHOUT applying the config update, but
///      the executor — flag now cleared — read the reused ACK envelope as a success and committed an epoch
///      the dispatcher never applied. That desync permanently NACKed every later command on the lane.
contract CommandCancelRetryRaceTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
    }

    /// @dev Queue a config update the dispatcher rejects: `vault_` passes the executor's shape check
    ///      (non-zero, unique) but fails the vault check in `StargateDispatcherLib.applyUpdateVaults`, so
    ///      `runBusinessSelf` reverts and the dispatcher NACKs. Leaves the command FAILED on both sides.
    ///      The dispatcher's allowlist edits happen inside the try/catch self-call, so they roll back.
    function _failingUpdateVaults(address vault_) internal returns (bytes32 commandId, uint64 sequence) {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        (,,,, commandId, sequence,) = executor.activeCommand(REMOTE_CHAIN);

        _relayAt(_lastSentIndex()); // executor -> dispatcher : UPDATE_VAULTS, reverts, NACK queued
        _relayAt(_lastSentIndex()); // dispatcher -> executor : NACK
        relayCursor = endpoint.sentCount();

        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "update failed on both sides");
    }

    // ---------------------------------------------------------------------
    // The regression itself
    // ---------------------------------------------------------------------

    function testShouldRejectRetryWhileCancelIsInFlight() public {
        _bringUpBothSides();
        (bytes32 commandId,) = _failingUpdateVaults(address(0xBEEF));

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        (,, bool awaitingCancel,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(awaitingCancel, "cancel armed");

        // The cancel is terminal once issued. A retry racing it can only misreport the outcome, so it is
        // refused outright instead of silently clearing the flag.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CancelInFlight.selector, REMOTE_CHAIN, commandId));
        executor.retryCommand(REMOTE_CHAIN);

        (,, bool stillAwaiting,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(stillAwaiting, "cancel flag survives the rejected retry");
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "status untouched by rejected retry");
    }

    /// @notice The PoC for the finding, end to end.
    /// @dev The operator cancels a FAILED config update and then reaches for a retry while the cancel is
    ///      still in flight. The CANCEL was sent first, so it also ARRIVES first (no message reordering is
    ///      needed — this is the natural ordering): the dispatcher resolves the command as CANCELLED and
    ///      applies nothing. Whether the retry is refused (the fix) or accepted (pre-fix), the executor's
    ///      epoch mirror must never end up claiming a config generation the dispatcher never applied.
    ///      Pre-fix, `buildRetry` cleared `awaitingCancel`, the cancel-resolution ACK was read as a
    ///      success, and the mirror advanced to 2 while the dispatcher stayed at 1 — permanently.
    function testShouldNotDesyncEpochWhenARetryRacesAnInFlightCancel() public {
        _bringUpBothSides();
        _failingUpdateVaults(address(0xBEEF));

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        uint256 cancelIndex = _lastSentIndex();

        // Tolerate either outcome: the invariant below must hold regardless of whether the retry is
        // accepted. That is what makes this a true regression test rather than a guard test.
        vm.prank(manager);
        try executor.retryCommand(REMOTE_CHAIN) {} catch {}

        _relayAt(cancelIndex); // CANCEL_COMMAND -> dispatcher; resolution ACK queued last
        _relayAt(_lastSentIndex()); // cancel-resolution ACK -> executor
        relayCursor = endpoint.sentCount();

        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher never applied the cancelled update");
        assertEq(
            executor.chainConfigEpoch(REMOTE_CHAIN),
            dispatcher.commandConfigEpoch(),
            "executor must not commit a config epoch the dispatcher never applied"
        );
    }

    function testShouldKeepEpochMirrorsInLockstepWhenCancelResolvesAFailedConfigUpdate() public {
        _bringUpBothSides();
        _failingUpdateVaults(address(0xBEEF));

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll(); // CANCEL_COMMAND -> dispatcher, cancel-resolution ACK -> executor

        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher never applied the cancelled update");
        assertEq(
            executor.chainConfigEpoch(REMOTE_CHAIN),
            dispatcher.commandConfigEpoch(),
            "executor mirror matches the dispatcher's authoritative epoch"
        );
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "slot freed by the cancel resolution");
    }

    /// @notice The impact the finding described: after a cancelled config update the command lane must
    ///         still work. A desynced mirror made every later command NACK with `ConfigEpochMismatch`.
    function testShouldKeepCommandLaneUsableAfterACancelledConfigUpdate() public {
        _bringUpBothSides();
        _allowRemoteVault(); // epochs -> 2
        _bridgeToDispatcher(100e6);

        _failingUpdateVaults(address(0xBEEF));
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();

        // A business command stamped with the (correctly unchanged) mirrored epoch is ACCEPTED, not NACKed
        // with `ConfigEpochMismatch` — this is the capital-stranding impact the finding described.
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        (,,,, bytes32 commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        _relayAll();

        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "business command resolved, lane alive");
        assertEq(
            uint8(dispatcher.commandStatus(commandId)),
            uint8(CommandStatus.SUCCEEDED),
            "dispatcher accepted the epoch the executor stamped"
        );
        assertGt(remoteVault.balanceOf(address(dispatcher)), 0, "capital actually deployed remotely");
    }

    /// @notice The other half of the described impact: a resync UPDATE_VAULTS must still be applicable
    ///         after a cancelled one. A desynced mirror made every later update NACK forever.
    function testShouldAllowAFurtherConfigUpdateAfterACancelledOne() public {
        _bringUpBothSides();
        _failingUpdateVaults(address(0xBEEF));

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();

        _allowRemoteVault();

        assertEq(dispatcher.commandConfigEpoch(), 2, "resync update applied on the dispatcher");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 2, "mirror followed");
        assertTrue(dispatcher.isAllowedVault(address(remoteVault)), "allowlist actually changed");
    }

    /// @notice The happy path still advances both epochs together — the fix must not freeze the mirror.
    function testShouldAdvanceBothEpochsOnASuccessfulConfigUpdate() public {
        _bringUpBothSides();
        _allowRemoteVault();

        assertEq(dispatcher.commandConfigEpoch(), 2, "dispatcher applied the update");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 2, "executor mirrored the advance");
        assertTrue(dispatcher.isAllowedVault(address(remoteVault)), "allowlist actually changed");
    }

    /// @notice A retry that legitimately succeeds (no cancel ever issued) still commits the epoch — the
    ///         `CancelInFlight` guard must not block the ordinary retry path.
    function testShouldCommitEpochWhenARetrySucceeds() public {
        _bringUpBothSides();

        // A real contract whose `asset()` is NOT the dispatcher's ASSET: `StargateDispatcherLib.applyUpdateVaults`
        // rejects it, so the first attempt NACKs.
        MockERC20 otherAsset = new MockERC20("Other", "OTH", 6);
        MockRemoteVault wrongAssetVault = new MockRemoteVault(IERC20(address(otherAsset)), "Wrong", "WRG");
        (bytes32 commandId,) = _failingUpdateVaults(address(wrongAssetVault));

        // Make the same address report the right asset, so the byte-identical retry passes validation.
        vm.mockCall(address(wrongAssetVault), abi.encodeWithSignature("asset()"), abi.encode(address(usdc)));

        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        _relayAll();

        assertEq(dispatcher.commandConfigEpoch(), 2, "retry applied the update on the dispatcher");
        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 2, "executor committed the epoch the retry produced");
        assertEq(
            uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "command resolved as success"
        );
    }
}
