// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {RescueModule} from "../../contracts/crosschain/lib/RescueModule.sol";
import {CrosschainConstants, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {
    ILayerZeroEndpointV2,
    MessagingParams,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";

/// @title RescueModuleTest
/// @notice Timelocked generic rescue + independent guardian veto, exercised through the executor (which
///         inherits `RescueModule`): schedule/execute after timelock, execute-before-timelock revert,
///         guardian veto + epoch, admin/guardian cancel, queue cap, the tracked-ledger invariant that
///         blocks taking tracked funds, and the shared force-resolve machinery (plan §4.3 / §6).
contract RescueModuleTest is CrosschainTestBase {
    /// @dev IL-8465: local re-declaration of the library event for `vm.expectEmit`.
    event ReturnRecordForceResolved(
        uint256 chainId,
        bytes32 requestId,
        uint8 outcome,
        uint256 inFlightRemovedSD,
        uint256 reserveToIdleSD
    );

    function setUp() public {
        _baseSetUp();
    }

    /// @dev Lifecycle tests (cancel / veto / queue cap) only need *a* queued record and never execute it.
    ///      They must not use the tracked asset as the target: calls to it are narrowed to
    ///      `transfer(address,uint256)`, so an empty-calldata placeholder against it is rejected at
    ///      schedule time.
    address internal constant PLACEHOLDER_TARGET = address(0xBEEF);

    function _stateOf(uint256 id_) internal view returns (uint8) {
        (, RescueModule.RescueState state,,,,,) = executor.rescues(id_);
        return uint8(state);
    }

    // ---------------------------------------------------------------------
    // Schedule / execute
    // ---------------------------------------------------------------------

    function testShouldScheduleAndExecuteAfterTimelock() public {
        usdc.mint(address(executor), 10e6); // untracked surplus (idle ledger is 0)
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 10e6));

        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);
        assertEq(_stateOf(id), uint8(RescueModule.RescueState.SCHEDULED), "scheduled");
        assertEq(executor.pendingRescueCount(), 1);

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeRescue(id, cd);

        assertEq(usdc.balanceOf(admin), 10e6, "surplus rescued to admin");
        assertEq(_stateOf(id), uint8(RescueModule.RescueState.EXECUTED), "executed");
        assertEq(executor.pendingRescueCount(), 0, "pending count decremented");
    }

    function testShouldRevertExecuteBeforeTimelock() public {
        usdc.mint(address(executor), 10e6);
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 10e6));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector, id, block.timestamp, block.timestamp + RESCUE_DELAY
            )
        );
        executor.executeRescue(id, cd);
    }

    function testShouldRejectWrongCalldataOnExecute() public {
        usdc.mint(address(executor), 10e6);
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 10e6));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueCalldataMismatch.selector, id));
        executor.executeRescue(id, abi.encodeCall(IERC20.transfer, (admin, 9e6)));
    }

    function testShouldBubbleTargetRevert() public {
        // Rescue call that reverts on the target (transfer more than the executor holds).
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 1_000e6));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(); // ERC20 insufficient-balance bubbles atomically
        executor.executeRescue(id, cd);
    }

    // ---------------------------------------------------------------------
    // Authorization
    // ---------------------------------------------------------------------

    function testShouldOnlyLetAdminSchedule() public {
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(0xdead)));
        executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
    }

    // ---------------------------------------------------------------------
    // Cancel + guardian veto
    // ---------------------------------------------------------------------

    function testShouldCancelByAdmin() public {
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
        vm.prank(admin);
        executor.cancelRescue(id);
        assertEq(_stateOf(id), uint8(RescueModule.RescueState.CANCELLED));

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueNotScheduled.selector, id));
        executor.executeRescue(id, "");
    }

    function testShouldCancelByGuardian() public {
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
        vm.prank(guardian);
        executor.cancelRescue(id);
        assertEq(_stateOf(id), uint8(RescueModule.RescueState.CANCELLED));
    }

    function testShouldRejectCancelByStranger() public {
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueCanceller.selector, address(0xdead)));
        executor.cancelRescue(id);
    }

    function testShouldLetGuardianVetoAllAndBumpEpoch() public {
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");

        vm.prank(guardian);
        executor.vetoAllPendingRescues();
        assertEq(executor.pendingRescueCount(), 0, "queue re-opened by global veto");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, id));
        executor.executeRescue(id, "");

        // A rescue scheduled AFTER the veto (new epoch) executes normally.
        usdc.mint(address(executor), 5e6);
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 5e6));
        vm.prank(admin);
        uint256 id2 = executor.scheduleRescue(address(usdc), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeRescue(id2, cd);
        assertEq(usdc.balanceOf(admin), 5e6, "post-veto rescue works");
    }

    function testShouldOnlyLetGuardianVetoAll() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueGuardian.selector, admin));
        executor.vetoAllPendingRescues();
    }

    // ---------------------------------------------------------------------
    // Queue cap
    // ---------------------------------------------------------------------

    function testShouldEnforceQueueCapAndReopenAfterVeto() public {
        uint256 cap = CrosschainConstants.MAX_PENDING_RESCUES;
        vm.startPrank(admin);
        for (uint256 i; i < cap; ++i) {
            executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
        }
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueQueueFull.selector, cap));
        executor.scheduleRescue(PLACEHOLDER_TARGET, 0, "");
        vm.stopPrank();

        assertEq(executor.pendingRescueCount(), cap, "queue full");

        vm.prank(guardian);
        executor.vetoAllPendingRescues();
        assertEq(executor.pendingRescueCount(), 0, "queue reset");

        vm.prank(admin);
        executor.scheduleRescue(PLACEHOLDER_TARGET, 0, ""); // cap re-opened
        assertEq(executor.pendingRescueCount(), 1);
    }

    // ---------------------------------------------------------------------
    // Tracked-ledger invariant (rescue may take untracked surplus only)
    // ---------------------------------------------------------------------

    function testShouldBlockRescueThatTakesTrackedFunds() public {
        _readyAndFundIdle40(); // idle = 40e6 backed by 40e6 USDC
        usdc.mint(address(executor), 10e6); // 10e6 untracked surplus; balance 50e6, tracked 40e6

        // A rescue of 20e6 would leave 30e6 < 40e6 tracked -> blocked by the ledger invariant.
        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 20e6));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueLedgerInvariantViolation.selector, uint256(30e6), uint256(40e6)
            )
        );
        executor.executeRescue(id, cd);
        assertEq(usdc.balanceOf(admin), 0, "transfer rolled back atomically");
    }

    function testShouldAllowRescueOfUntrackedSurplusOnly() public {
        _readyAndFundIdle40();
        usdc.mint(address(executor), 10e6); // exactly the surplus

        bytes memory cd = abi.encodeCall(IERC20.transfer, (admin, 10e6));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(usdc), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeRescue(id, cd);
        assertEq(usdc.balanceOf(admin), 10e6, "surplus rescued");
        assertEq(usdc.balanceOf(address(executor)), 40e6, "tracked backing preserved");
    }

    // ---------------------------------------------------------------------
    // Protected-asset guard: the balance snapshot cannot police *authorisations*
    // ---------------------------------------------------------------------

    /// @notice The tracked-ledger invariant is enforced by a post-call balance snapshot, which an
    ///         `approve` leaves untouched. Without the schedule-time guard the admin could grant itself
    ///         an allowance over the whole tracked balance, pass `_afterRescueExecuted`, and then pull
    ///         the tracked tokens in a plain `transferFrom` — outside the timelock, outside the
    ///         guardian's veto window, and with `idleLedger` left intact so NAV still reports the
    ///         drained value. The full drain is asserted to be impossible below.
    function testShouldBlockRescueGrantingAllowanceOverTrackedAsset() public {
        _readyAndFundIdle40(); // idle = 40e6, fully backed
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector, address(usdc), IERC20.approve.selector
            )
        );
        executor.scheduleRescue(address(usdc), 0, cd);

        // No allowance was granted, so the tracked backing cannot be pulled afterwards.
        assertEq(usdc.allowance(address(executor), admin), 0, "no allowance over tracked asset");
        vm.prank(admin);
        vm.expectRevert();
        usdc.transferFrom(address(executor), admin, 40e6);
        assertEq(usdc.balanceOf(address(executor)), 40e6, "tracked backing intact");
        assertEq(executor.idleLedger(), 40e6, "ledger unchanged");
    }

    /// @notice The guard is selector-based, not `approve`-specific: any non-`transfer` shape against the
    ///         tracked asset (operator grants, permit-likes, unknown extensions) is rejected.
    function testShouldBlockAnyNonTransferSelectorOnTrackedAsset() public {
        _readyAndFundIdle40();
        bytes memory cd = abi.encodeWithSignature("authorizeOperator(address)", admin);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector,
                address(usdc),
                bytes4(keccak256("authorizeOperator(address)"))
            )
        );
        executor.scheduleRescue(address(usdc), 0, cd);
    }

    /// @notice A `transfer` selector with trailing bytes could dispatch differently on a non-standard
    ///         asset, so the guard pins the exact 4 + 32 + 32 calldata length.
    function testShouldBlockPaddedTransferOnTrackedAsset() public {
        _readyAndFundIdle40();
        bytes memory cd = bytes.concat(abi.encodeCall(IERC20.transfer, (admin, 1)), hex"00");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector, address(usdc), IERC20.transfer.selector
            )
        );
        executor.scheduleRescue(address(usdc), 0, cd);
    }

    /// @notice Only the tracked asset is narrowed — rescuing an unrelated token stuck on the executor
    ///         keeps the full arbitrary-calldata power the rescue queue exists for.
    function testShouldStillAllowArbitraryRescueOfUnrelatedToken() public {
        _readyAndFundIdle40();
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, 5e18));

        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(other), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeRescue(id, cd);
        assertEq(other.allowance(address(executor), admin), 5e18, "unrelated token rescue unaffected");
    }

    // ---------------------------------------------------------------------
    // IL-8555 / IL-8556 fences (executor side)
    // ---------------------------------------------------------------------

    function _lzSend() internal view returns (bytes memory) {
        return abi.encodeCall(
            ILayerZeroEndpointV2.send,
            (
                MessagingParams({
                    dstEid: REMOTE_EID, receiver: bytes32(0), message: "", options: "", payInLzToken: false
                }),
                admin
            )
        );
    }

    /// @notice A rescue `endpoint.send` would forge a peer-authenticated message from the host's address.
    function testShouldBlockRescueSendThroughLzEndpoint() public {
        bytes memory cd = _lzSend();
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTransportCall.selector, address(endpoint), ILayerZeroEndpointV2.send.selector
            )
        );
        executor.scheduleRescue(address(endpoint), 0, cd);
    }

    function testShouldBlockRescueSetDelegateOnLzEndpoint() public {
        bytes memory cd = abi.encodeCall(ILayerZeroEndpointV2.setDelegate, (admin));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTransportCall.selector,
                address(endpoint),
                ILayerZeroEndpointV2.setDelegate.selector
            )
        );
        executor.scheduleRescue(address(endpoint), 0, cd);
    }

    function testShouldBlockRescueToLzEndpointWithEmptyCalldata() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueTransportCall.selector, address(endpoint), bytes4(0))
        );
        executor.scheduleRescue(address(endpoint), 0, "");
    }

    /// @notice Inbound packet hygiene (`clear`, `skip`, `nilify`, `burn`) stays available and executes end to end.
    function testShouldAllowRescueClearAndSkipOnLzEndpoint() public {
        bytes memory clearCd = abi.encodeCall(
            ILayerZeroEndpointV2.clear,
            (address(executor), Origin({srcEid: REMOTE_EID, sender: bytes32(0), nonce: 1}), bytes32(0), "")
        );
        bytes memory skipCd = abi.encodeWithSignature(
            "skip(address,uint32,bytes32,uint64)", address(executor), REMOTE_EID, bytes32(0), uint64(1)
        );
        assertEq(bytes4(clearCd), bytes4(0x2a56c1b0), "clear selector pinned");
        assertEq(bytes4(skipCd), bytes4(0xd70b8902), "skip selector pinned");

        bytes memory nilifyCd = abi.encodeWithSignature(
            "nilify(address,uint32,bytes32,uint64,bytes32)",
            address(executor),
            REMOTE_EID,
            bytes32(0),
            uint64(1),
            bytes32(0)
        );
        bytes memory burnCd = abi.encodeWithSignature(
            "burn(address,uint32,bytes32,uint64,bytes32)",
            address(executor),
            REMOTE_EID,
            bytes32(0),
            uint64(1),
            bytes32(0)
        );
        assertEq(bytes4(nilifyCd), bytes4(0x2e80fbf3), "nilify selector pinned");
        assertEq(bytes4(burnCd), bytes4(0x40f80683), "burn selector pinned");

        vm.startPrank(admin);
        uint256 clearId = executor.scheduleRescue(address(endpoint), 0, clearCd);
        uint256 skipId = executor.scheduleRescue(address(endpoint), 0, skipCd);
        uint256 nilifyId = executor.scheduleRescue(address(endpoint), 0, nilifyCd);
        uint256 burnId = executor.scheduleRescue(address(endpoint), 0, burnCd);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        executor.executeRescue(clearId, clearCd);
        executor.executeRescue(skipId, skipCd);
        executor.executeRescue(nilifyId, nilifyCd);
        executor.executeRescue(burnId, burnCd);
        vm.stopPrank();
        assertEq(_stateOf(nilifyId), uint8(RescueModule.RescueState.EXECUTED));
        assertEq(_stateOf(burnId), uint8(RescueModule.RescueState.EXECUTED));
        assertEq(_stateOf(clearId), uint8(RescueModule.RescueState.EXECUTED));
        assertEq(_stateOf(skipId), uint8(RescueModule.RescueState.EXECUTED));
    }

    /// @notice The tracked-vault fence is dispatcher-scoped: an executor has no tracked set, so a rescue
    ///         on an arbitrary ERC-4626 (e.g. one an operator mistakenly deposited into) stays arbitrary.
    function testShouldNotApplyTrackedVaultFenceOnExecutor() public {
        MockRemoteVault someVault = new MockRemoteVault(IERC20(address(usdc)), "V", "V");
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        uint256 id = executor.scheduleRescue(address(someVault), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeRescue(id, cd);
        assertEq(someVault.allowance(address(executor), admin), type(uint256).max);
    }

    // ---------------------------------------------------------------------
    // Force-resolve (shared delay / veto / epoch machinery)
    // ---------------------------------------------------------------------

    function testShouldForceResolveStuckOutboundDropFromNav() public {
        _readyDispatcher();
        (bytes32 transferId,,) = _sendAsset(100e6, 0);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e6, "outbound counted");

        vm.prank(admin);
        uint256 id = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(id, transferId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "dropped from NAV");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 0, "NAV cleared of the dead transfer");
    }

    function testShouldForceResolveStuckOutboundToSettled() public {
        _readyDispatcher();
        (bytes32 transferId,,) = _sendAsset(100e6, 0);
        vm.prank(admin);
        uint256 id = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(id, transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "moved to settled");
    }

    function testShouldForceDropMetadataFirstReturnAndIgnoreLateCompose() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 39e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6);
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 39e6);

        vm.prank(admin);
        uint256 id = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        // IL-8465: metadata-only DROP_FROM_NAV reports the expected credit removed from returnInFlight.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnRecordForceResolved(REMOTE_CHAIN, requestId, uint8(ResolveOutcome.DROP_FROM_NAV), 39e6, 0);
        executor.executeForceResolveTransfer(id, requestId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "expected return dropped");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "slot released once");
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 60e6, "only remote remainder stays in NAV");

        usdc.mint(address(executor), 39e6);
        _deliverReturnCompose(requestId, RGUID, 39e6);

        assertEq(executor.idleLedger(), 0, "late compose cannot recreate idle");
        assertEq(executor.pendingArrivalReserve(), 0, "late compose cannot recreate reserve");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "late compose cannot release twice");
        assertEq(usdc.balanceOf(address(executor)), 39e6, "late tokens remain untracked rescue surplus");
    }

    function testShouldRejectReturnedToIdleAtScheduleTimeWhenComposeArrivesBeforeMetadata() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        usdc.mint(address(executor), 39e6);
        _deliverReturnCompose(requestId, RGUID, 39e6);
        uint256 pendingBefore = executor.pendingRescueCount();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveWrongState.selector, requestId));
        executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.RETURNED_TO_IDLE);

        assertEq(executor.pendingRescueCount(), pendingBefore, "no rescue slot taken");
        assertEq(executor.pendingArrivalReserve(), 39e6, "reserve preserved");
        assertEq(executor.idleLedger(), 0, "no premature idle credit");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled remains sole NAV bucket");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "capacity remains reserved without a timestamp");
    }

    function testShouldApplyLateMetadataDebitAfterNoLegDropAndIgnoreLateCompose() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);

        vm.prank(admin);
        uint256 id = executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        // IL-8465: a no-leg DROP moves nothing and says so.
        vm.expectEmit(false, false, false, true, address(executor));
        emit ReturnRecordForceResolved(REMOTE_CHAIN, requestId, uint8(ResolveOutcome.DROP_FROM_NAV), 0, 0);
        executor.executeForceResolveTransfer(id, requestId, ResolveOutcome.DROP_FROM_NAV);

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "abandoned request releases slot");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "no remote debit known yet");

        _deliverReturnStarted(requestId, RGUID, 40e6, 39e6, 2);
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 2, "late metadata advances frontier");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "late remote debit applied once");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 0, "terminal record does not recreate in-flight");

        usdc.mint(address(executor), 39e6);
        _deliverReturnCompose(requestId, RGUID, 39e6);
        _deliverReturnStarted(requestId, RGUID, 40e6, 39e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 60e6, "duplicate metadata cannot debit twice");
        assertEq(executor.idleLedger(), 0, "late compose remains untracked");
        assertEq(executor.pendingArrivalReserve(), 0, "late compose cannot recreate reserve");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "terminal slot stays released");
    }

    function testShouldRejectReturnedToIdleAtScheduleTimeForMetadataOnlyReturn() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 39e6, 2);
        uint256 pendingBefore = executor.pendingRescueCount();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveWrongState.selector, requestId));
        executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.RETURNED_TO_IDLE);

        assertEq(executor.pendingRescueCount(), pendingBefore, "no rescue slot taken");
        assertEq(executor.idleLedger(), 0, "expected amount never becomes unbacked idle");
        assertEq(executor.returnInFlight(REMOTE_CHAIN), 39e6, "record remains pending");
    }

    function testShouldRejectReturnedToIdleAtScheduleTimeForUnsettledOutboundTransfer() public {
        _readyDispatcher();
        (bytes32 transferId,,) = _sendAsset(100e6, 0);
        uint256 pendingBefore = executor.pendingRescueCount();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveWrongState.selector, transferId));
        executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.RETURNED_TO_IDLE);

        assertEq(executor.pendingRescueCount(), pendingBefore, "no rescue slot taken");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "outbound record remains pending");
    }

    function testShouldRejectReturnedToIdleAtScheduleTimeForRecallWithNoLegArrived() public {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        uint256 pendingBefore = executor.pendingRescueCount();

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveWrongState.selector, requestId));
        executor.scheduleForceResolveTransfer(requestId, ResolveOutcome.RETURNED_TO_IDLE);

        assertEq(executor.pendingRescueCount(), pendingBefore, "no rescue slot taken");
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "recall record remains pending");
    }

    function testShouldVetoScheduledForceResolve() public {
        _readyDispatcher();
        (bytes32 transferId,,) = _sendAsset(100e6, 0);
        vm.prank(admin);
        uint256 id = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DROP_FROM_NAV);

        vm.prank(guardian);
        executor.vetoAllPendingRescues();

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, id));
        executor.executeForceResolveTransfer(id, transferId, ResolveOutcome.DROP_FROM_NAV);
    }

    function testShouldOnlyLetAdminScheduleForceResolve() public {
        _readyDispatcher();
        (bytes32 transferId,,) = _sendAsset(100e6, 0);
        vm.prank(address(0xdead));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(0xdead)));
        executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DROP_FROM_NAV);
    }
}
