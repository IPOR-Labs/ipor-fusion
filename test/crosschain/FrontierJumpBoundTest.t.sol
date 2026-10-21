// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipChainRescue,
    ResolveOutcome,
    MsgType,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";

/// @title StargateFrontierJumpBoundTest
/// @notice Regression cover for
///         `unbounded_irreversible_state_version_jump_silently_swallows_authenticated_messages`.
///
///         `ADVANCE_STATE_FRONTIER` is the one write that moves the anti-replay frontier with no
///         authenticated message behind it, and it is irreversible — the frontier is monotonic in both
///         writers, so `applyForceResolve` rejects any corrective value as `StateVersionGap`. It used to
///         accept ANY value strictly greater than the current one. Every version the jump lands past is
///         then classified by `_advanceVersionFrontier` as an "older duplicate", and all four call sites
///         answer that by returning before applying the message's accounting. Overshoot the dispatcher's
///         real counter and the lane is not damaged for a window — it is dead: every future settlement,
///         return metadata and command ACK from that chain is consumed as a no-op, forever, on a
///         non-upgradeable contract.
///
///         The fix is a bound on how far one repair may skip (`MAX_FRONTIER_JUMP`). It cannot catch an
///         off-by-one — nothing on this chain can observe the remote counter — so it is paired with a
///         detector: a version-bearing message dropped as a "duplicate" while its record is still OPEN is
///         surfaced as `AuthenticatedMessageDroppedAheadOfFrontier`, which a genuine LayerZero re-delivery
///         can never trigger (it finds its record already resolved).
contract StargateFrontierJumpBoundTest is CrosschainTestBase {
    event AuthenticatedMessageDroppedAheadOfFrontier(
        uint256 srcChainId, uint8 msgType, bytes32 recordId, uint64 stateVersion, uint64 frontier
    );

    bytes32 private constant DROPPED_TOPIC =
        keccak256("AuthenticatedMessageDroppedAheadOfFrontier(uint256,uint8,bytes32,uint64,uint64)");

    function setUp() public {
        _baseSetUp();
        _readyDispatcher(); // frontier == 0 (a command ACK is value-neutral, IL-8257)
    }

    function _frontierId(uint256 newVersion_) private pure returns (bytes32) {
        return bytes32((uint256(REMOTE_CHAIN) << 64) | newVersion_);
    }

    /// @dev Schedule a frontier repair and warp past its dedicated 6h timelock. Stargate validates the
    ///      target at EXECUTE time only — the schedule path stores an opaque commitment hash, and an
    ///      executor-side pre-check does not fit its 78-byte EIP-170 margin — so scheduling always
    ///      succeeds and the reverting tests expect on `_executeRepair`.
    function _scheduleRepair(uint256 newVersion_) private returns (uint256 rescueId) {
        vm.prank(admin);
        rescueId =
            executor.scheduleForceResolveTransfer(_frontierId(newVersion_), ResolveOutcome.ADVANCE_STATE_FRONTIER);
        vm.warp(block.timestamp + CrosschainConstants.FRONTIER_REPAIR_DELAY);
    }

    function _executeRepair(uint256 rescueId_, uint256 newVersion_) private {
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId_, _frontierId(newVersion_), ResolveOutcome.ADVANCE_STATE_FRONTIER);
    }

    function _repairFrontier(uint256 newVersion_) private {
        _executeRepair(_scheduleRepair(newVersion_), newVersion_);
    }

    /// @notice The headline defect, with the audit PoC's own value: a mis-scaled `2 << 32` was accepted and
    ///         killed the lane permanently. It must now revert, and the frontier must be untouched.
    function testMisScaledFrontierJumpIsRejected() public {
        uint64 before = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint256 rescueId = _scheduleRepair(uint256(2) << 32);

        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.FrontierAdvanceTooLarge.selector,
                REMOTE_CHAIN,
                before,
                uint256(2) << 32,
                CrosschainConstants.MAX_FRONTIER_JUMP
            )
        );
        _executeRepair(rescueId, uint256(2) << 32);

        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), before, "a rejected repair writes nothing");
    }

    /// @notice A fat-fingered extra digit is the same class of error and must fail the same way.
    function testFatFingeredExtraDigitIsRejected() public {
        uint256 rescueId = _scheduleRepair(220); // meant 22
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.FrontierAdvanceTooLarge.selector,
                REMOTE_CHAIN,
                uint64(0),
                uint256(220),
                CrosschainConstants.MAX_FRONTIER_JUMP
            )
        );
        _executeRepair(rescueId, 220);
    }

    /// @notice Exact cap boundary: `current + MAX_FRONTIER_JUMP` is the largest legitimate repair.
    function testRepairAtTheCapIsAccepted() public {
        uint64 before = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        _repairFrontier(uint256(before) + CrosschainConstants.MAX_FRONTIER_JUMP);
        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            before + uint64(CrosschainConstants.MAX_FRONTIER_JUMP),
            "the cap itself is allowed"
        );
    }

    /// @notice One past the cap is rejected — the bound is inclusive on the cap, exclusive above it.
    function testRepairOnePastTheCapIsRejected() public {
        uint64 before = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        uint256 target = uint256(before) + CrosschainConstants.MAX_FRONTIER_JUMP + 1;
        uint256 rescueId = _scheduleRepair(target);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.FrontierAdvanceTooLarge.selector,
                REMOTE_CHAIN,
                before,
                target,
                CrosschainConstants.MAX_FRONTIER_JUMP
            )
        );
        _executeRepair(rescueId, target);
    }

    /// @notice The guard must not block the flow the rescue exists for: skipping one permanently lost
    ///         message still advances the frontier and still leaves the chain fail-closed.
    function testOneStepRepairStillWorks() public {
        _repairFrontier(1);

        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier advanced");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "repair leaves the chain fail-closed");
    }

    /// @notice Repeated repairs are the documented escape for a genuinely larger gap: the cap adds friction
    ///         (and a 6h timelock per step) rather than removing the capability.
    function testALargerGapIsRepairableInSteps() public {
        _repairFrontier(CrosschainConstants.MAX_FRONTIER_JUMP);
        _repairFrontier(2 * CrosschainConstants.MAX_FRONTIER_JUMP);
        assertEq(
            executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            uint64(2 * CrosschainConstants.MAX_FRONTIER_JUMP),
            "two steps reach twice the cap"
        );
    }

    /// @notice The detector, on the residue the cap cannot catch. A SMALL overshoot (within the cap, so it
    ///         is accepted) still swallows a genuine settlement — that is unavoidable, no on-chain check can
    ///         see the remote counter. What must not happen is that it does so silently.
    function testSmallOvershootSurfacesTheSwallowedSettlement() public {
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        // The real next version is 1; the operator overshoots to 2.
        _repairFrontier(2);

        vm.expectEmit(false, false, false, true, address(executor));
        emit AuthenticatedMessageDroppedAheadOfFrontier(REMOTE_CHAIN, uint8(MsgType.TRANSFER_SETTLED), transferId, 1, 2);
        _deliverTransferSettled(transferId, guid, 100e6, 1);

        // The damage is real and is NOT claimed to be fixed by this change: the settlement was dropped.
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 100e6, "value still stranded in flight");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settlement never applied");
    }

    /// @notice Same detector on the recall lane: swallowed RETURN_STARTED metadata is the debit that keeps
    ///         `settledRemoteBalance` counting value the remote side has already sent.
    function testSmallOvershootSurfacesTheSwallowedReturnMetadata() public {
        _settle100(); // frontier == 1, settled == 100e6
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _repairFrontier(3); // real next version is 2

        vm.expectEmit(false, false, false, true, address(executor));
        emit AuthenticatedMessageDroppedAheadOfFrontier(REMOTE_CHAIN, uint8(MsgType.RETURN_STARTED), requestId, 2, 3);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "remote debit never applied");
    }

    /// @notice The detector must be silent on the flow it most resembles: an ordinary LayerZero re-delivery.
    ///         A true duplicate finds its record already resolved and short-circuits BEFORE the frontier
    ///         check, so it must not raise the alert (or the event is noise and monitoring will ignore it).
    function testAGenuineDuplicateDoesNotAlert() public {
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        _deliverTransferSettled(transferId, guid, 100e6, 1);

        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, 100e6, 1); // honest LZ retry
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != DROPPED_TOPIC, "a normal duplicate must not raise the alert");
        }
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "idempotent, applied exactly once");
    }
}

contract JumpToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}
}

/// @title CcipFrontierJumpBoundTest
/// @notice The sibling transport had the identical unbounded advance, filed separately as
///         `unbounded_one_way_frontier_advance_permanently_disables_version_check`. Its impact differs —
///         CCIP applies the accounting BEFORE `acceptRemoteStateVersion`, so an overshoot does not swallow
///         value, it makes the anti-replay frontier permanently inert and lets `propose` be satisfied
///         forever with one frozen version — but the root cause and the fix are the same.
///
///         CCIP also had a truncation hole the Stargate packing does not: `arg_` is a `uint256` compared as
///         a `uint256`, then stored as `uint64(arg_)`. Without an upper bound, `2**64 + n` passed the
///         strictly-greater check and stored `n`, moving the frontier BACKWARDS.
contract CcipFrontierJumpBoundTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    JumpToken internal token;
    CcipCrosschainExecutor internal executor;

    function setUp() public {
        router = new MockCcipRouter();
        token = new JumpToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        executor = new CcipCrosschainExecutor(
            address(router), address(routeValidator), address(this), address(token), keccak256("USDC"), 18, _safety()
        );
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(0xDEAD),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        vm.prank(address(routeValidator));
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: RESCUE_ADMIN,
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: APPROVER,
            rescueDelay: RESCUE_DELAY,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function _schedule(uint256 newVersion_) private returns (uint256 rescueId) {
        vm.prank(RESCUE_ADMIN);
        rescueId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
    }

    function _repairFrontier(uint256 newVersion_) private {
        uint256 rescueId = _schedule(newVersion_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, newVersion_);
    }

    /// @notice Mis-scaled target rejected — and, unlike Stargate, already at schedule time, so the operator
    ///         learns immediately instead of 3 days later.
    function testMisScaledFrontierJumpIsRejectedAtScheduleTime() public {
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.InvalidFrontierAdvance.selector, uint64(0), uint64(2 << 32))
        );
        _schedule(uint256(2) << 32);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 0, "nothing written");
    }

    /// @notice The truncation hole: `2**64 + 5` compares as a huge `uint256` and stored as `uint64` it
    ///         becomes 5. From a frontier of 10 that is a BACKWARDS move — an anti-replay frontier that goes
    ///         down re-opens every version between. The cap makes the cast unreachable for any accepted
    ///         value.
    function testTruncatingJumpCannotMoveTheFrontierBackwards() public {
        _repairFrontier(10);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 10, "frontier at 10");

        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainExecutor.InvalidFrontierAdvance.selector, uint64(10), uint64(5))
        );
        _schedule((uint256(1) << 64) + 5);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 10, "frontier never moved backwards");
    }

    /// @notice Cap boundary, both sides.
    function testCapBoundary() public {
        _repairFrontier(CrosschainConstants.MAX_FRONTIER_JUMP);
        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(CrosschainConstants.MAX_FRONTIER_JUMP),
            "the cap itself is allowed"
        );

        uint256 tooFar = 2 * CrosschainConstants.MAX_FRONTIER_JUMP + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainExecutor.InvalidFrontierAdvance.selector,
                uint64(CrosschainConstants.MAX_FRONTIER_JUMP),
                uint64(tooFar)
            )
        );
        _schedule(tooFar);
    }

    /// @notice The rescue's own purpose is intact: a one-step repair still advances and still blocks.
    function testOneStepRepairStillWorks() public {
        _repairFrontier(1);
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 1, "frontier advanced");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "repair leaves the chain fail-closed");
        assertTrue(executor.frontierRepairPending(REMOTE_CHAIN), "repair latch armed");
    }
}
