// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorAttestationLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorAttestationLib.sol";
import {CcipChainRescue, ResolveOutcome} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {AnchorBandToken} from "./AttestationAnchorBandTest.t.sol";

/// @title StargateAttestationAnchorNetPrincipalTest
/// @notice Regression cover for IL-8578 / TP-H-02 (Stargate): the anchor was credited IN FULL on re-supply
///         while a recall debits it pro rata against the ATTESTED `settled`, so each recall / re-supply
///         round trip added ~0.2x of attestable headroom with no new capital. The credit is now capped at
///         `netPrincipal` (floored at the band-consistency minimum). Stargate exposes no anchor/net getter
///         (EIP-170 headroom), so both are read from the `AttestationAnchorUpdated` /
///         `AttestationNetPrincipalUpdated` / `AttestationAnchorRebased` events.
contract StargateAttestationAnchorNetPrincipalTest is CrosschainTestBase {
    uint256 internal constant V = 100e6;

    bytes32 internal constant ANCHOR_UPDATED_TOPIC = keccak256("AttestationAnchorUpdated(uint256,uint256)");
    bytes32 internal constant ANCHOR_REBASED_TOPIC = keccak256("AttestationAnchorRebased(uint256,uint256)");
    bytes32 internal constant NET_UPDATED_TOPIC = keccak256("AttestationNetPrincipalUpdated(uint256,uint256)");

    uint256 internal anchor;
    uint256 internal net;
    uint64 internal version;

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
    }

    function _sync() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == ANCHOR_UPDATED_TOPIC || t == ANCHOR_REBASED_TOPIC) {
                (, anchor) = abi.decode(logs[i].data, (uint256, uint256));
            } else if (t == NET_UPDATED_TOPIC) {
                (, net) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    /// @dev ceil(settled * 10_000 / 12_000), the band-consistency floor, derived independently.
    function _ceilFloor(uint256 settled_) internal pure returns (uint256) {
        return (settled_ * 10_000 + 11_999) / 12_000;
    }

    function _propose(uint256 settledLD_) internal returns (uint256 proposalId) {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN),
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        return executor.proposalCount();
    }

    function _attest(uint256 settledLD_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(settledLD_);
        vm.prank(approver);
        executor.approveBalance(pid);
    }

    /// @dev Bridge and settle `amount_` through an authenticated TRANSFER_SETTLED.
    function _supply(uint256 amount_) internal {
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(amount_, 0);
        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, amount_, ++version);
        _sync();
    }

    /// @dev Recall `amount_` (dispatcher returns exactly that) and deliver the tokens.
    function _recall(uint256 amount_) internal {
        (bytes32 requestId, , ) = _requestAssets(amount_, 0);
        vm.recordLogs();
        _deliverReturnStarted(requestId, RGUID, amount_, amount_, ++version);
        usdc.mint(address(executor), amount_);
        _deliverReturnCompose(requestId, RGUID, amount_);
        _sync();
    }

    function _expectBandRevertAt(uint256 proposed_, uint256 principal_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(proposed_);
        vm.prank(approver);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                principal_,
                proposed_,
                2_000
            )
        );
        executor.approveBalance(pid);
    }

    /// @dev Supply V and attest it to 1.2V in two compliant 10% steps; anchor V, net V, settled 1.2V.
    function _inflateToBandTop() internal {
        _supply(V);
        _attest(110e6);
        _attest(120e6);
    }

    function testRoundTripShouldNotRaiseAnchorAboveNetPrincipal() public {
        _inflateToBandTop();
        assertEq(anchor, V);
        assertEq(net, V);

        _recall(V); // pro rata: anchor V/6, settled 0.2V, net 0
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e6, "0.2V residue");
        assertEq(net, 0, "net debited by the amount the dispatcher sent back");
        _supply(V); // old behaviour: anchor 7V/6

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6, "settled 1.2V");
        assertEq(net, V, "net is the verifiably placed principal");
        assertEq(anchor, V, "anchor capped at net principal, not 7V/6");
        _expectBandRevertAt(130e6, V);
    }

    function testFiveRoundTripsShouldKeepAnchorFlat() public {
        _inflateToBandTop();
        for (uint256 i; i < 5; ++i) {
            _recall(V);
            _supply(V);
            assertLe(anchor, V, "anchor never exceeds V");
            assertLe(net, V, "net never exceeds V");
        }
        assertEq(anchor, V);
        _expectBandRevertAt(130e6, V);
    }

    function testHonestYieldResidueAfterFullRecallShouldStayAttestable() public {
        _supply(V);
        _attest(110e6);
        _recall(V); // leaves 0.1V honest yield residue, net 0
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10e6);
        assertEq(net, 0);
        _supply(10e6); // top-up 0.1V

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e6);
        assertEq(net, 10e6, "net counts only the top-up");
        assertEq(anchor, _ceilFloor(20e6), "band-consistency floor fired: ceil(0.2V / 1.2)");
        assertGt(anchor, net, "floor lifted the anchor above the net cap");
        _attest(20e6); // approvable, attestation is not frozen
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e6);
    }

    function testPartialRecallThenResupplyShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(50e6);
        assertEq(net, 50e6);
        _supply(50e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6);
        assertEq(net, V);
        assertEq(anchor, V, "anchor capped at net principal");
        _expectBandRevertAt(130e6, V);
    }

    function testForceSetShouldRebaseNetPrincipal() public {
        vm.recordLogs();
        uint64 observedVersion = executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN);
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceSetSettledBalance(
            REMOTE_CHAIN, 150e6, observedVersion, _markFsObs(), false
        );
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceSetSettledBalance(rescueId, REMOTE_CHAIN, 150e6, observedVersion, fsObs, false);
        _sync();
        assertEq(anchor, 150e6);
        assertEq(net, 150e6, "net rebased with the anchor");

        _supply(10e6);
        assertEq(net, 160e6);
        assertEq(anchor, 160e6, "anchor not capped down below the rebased value");
        _attest(170e6); // would revert if net had stayed at 10e6 (anchor would be the 133.3e6 floor)
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 170e6);
    }

    function testDustToZeroShouldResetNetPrincipal() public {
        _supply(5_000); // within ATTESTATION_ZERO_DUST_SD
        assertEq(net, 5_000);
        assertEq(anchor, 5_000);
        vm.recordLogs();
        _attest(0);
        _sync();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(anchor, 0, "anchor reset");
        assertEq(net, 0, "net reset with the anchor");
    }

    /// @notice The `DELIVERED_TO_SETTLED` force-resolve credit (`applyForceResolve` site) is capped too.
    function testDeliveredToSettledForceResolveShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(V);
        (bytes32 transferId, , ) = _sendAsset(V, 0); // stuck: never settled by an authenticated receipt
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.recordLogs();
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferId, ResolveOutcome.DELIVERED_TO_SETTLED);
        _sync();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6, "settled 1.2V");
        assertEq(net, V, "net is the verifiably placed principal");
        assertEq(anchor, V, "anchor capped at net principal, not 7V/6");
        _expectBandRevertAt(130e6, V);
    }

    /// @dev Recall `amount_`; the attester pair approves `mid1_` then `mid2_` (0 = skip) BEFORE RETURN_STARTED
    ///      arrives. The dispatcher still sends `amount_` (the bound is fixed at request time).
    function _recallWithInFlightApprovals(uint256 amount_, uint256 mid1_, uint256 mid2_) internal {
        (bytes32 requestId, , uint256 maxAccountedSD) = _requestAssets(amount_, 0);
        assertEq(maxAccountedSD, amount_, "bound fixed at request time");
        if (mid1_ != 0) _attest(mid1_);
        if (mid2_ != 0) _attest(mid2_);
        vm.recordLogs();
        _deliverReturnStarted(requestId, RGUID, amount_, amount_, ++version);
        usdc.mint(address(executor), amount_);
        _deliverReturnCompose(requestId, RGUID, amount_);
        _sync();
    }

    /// @notice IL-8578 review: an approval that lowers `settled` while a recall is in flight must not leave
    ///         phantom units in `netPrincipal`; the debit is the amount the dispatcher declared it sent.
    function testInFlightApprovalShouldNotLeavePhantomNetPrincipal() public {
        _supply(V);
        _recallWithInFlightApprovals(V, 90e6, 81e6);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied");
        assertEq(anchor, 0, "anchor reached zero with the bucket");
        assertEq(net, 0, "net debited by the amount the dispatcher sent, not by the settled delta");
    }

    /// @notice IL-8578 review: three round trips with in-flight approvals leave no phantom principal, so the
    ///         TP-H-02 ratchet stays closed (the anchor is capped at V, 130e6 is outside the band).
    function testInFlightApprovalsShouldNotReopenRatchetAfterThreeRoundTrips() public {
        for (uint256 i; i < 3; ++i) {
            _supply(V);
            _recallWithInFlightApprovals(V, 90e6, 81e6);
            assertEq(net, 0, "no phantom net principal after a round trip");
        }

        _supply(V);
        assertEq(net, V);
        assertEq(anchor, V);
        _attest(110e6);
        _attest(120e6);
        _recall(V);
        _supply(V);
        assertEq(net, V, "net is the verifiably placed principal");
        assertEq(anchor, V, "anchor capped at net principal, not inflated");
        _expectBandRevertAt(130e6, V);
    }

    /// @notice Documented limitation (IL-8578 review): a realised loss stays in `netPrincipal` after the bucket
    ///         is emptied (supply 100, attest 90, recall 90 leaves 10). It is bounded by real losses and clears
    ///         on `forceSetSettled`; it is not an attacker-controlled amount.
    function testRealisedLossStaysInNetPrincipalKnownLimitation() public {
        _supply(V);
        _attest(90e6);
        _recall(90e6);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(anchor, 0);
        assertEq(net, 10e6, "the lost 0.1V is still net principal");
    }

    /// @notice The late `TRANSFER_SETTLED` credit (`_applyLateCredit` site, IL-8619) after a DROP_FROM_NAV is
    ///         capped at `netPrincipal` too; replacing `_creditAnchor` there with `anchor += credited` fails this.
    function testLateCreditShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(V);
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(V, 0); // stuck: settlement not delivered yet
        vm.prank(admin);
        uint256 rescueId = executor.scheduleForceResolveTransfer(transferId, ResolveOutcome.DROP_FROM_NAV);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        executor.executeForceResolveTransfer(rescueId, transferId, ResolveOutcome.DROP_FROM_NAV);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e6, "dropped, not yet credited");

        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, V, ++version); // the genuine settlement arrives late
        _sync();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e6, "settled 1.2V");
        assertEq(net, V, "net is the verifiably placed principal");
        assertEq(anchor, V, "anchor capped at net principal, not 7V/6");
        _expectBandRevertAt(130e6, V);
    }
}

/// @title CcipAttestationAnchorNetPrincipalTest
/// @notice CCIP mirror of `StargateAttestationAnchorNetPrincipalTest` (IL-8578 / TP-H-02); the anchor and the
///         net principal are read through `attestationAnchorPrincipal` / `attestationNetPrincipal`.
contract CcipAttestationAnchorNetPrincipalTest is Test {
    using stdStorage for StdStorage;

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant MIN_UPDATE_INTERVAL = 1 hours;
    uint256 internal constant V = 100e18;

    MockCcipRouter internal router;
    AnchorBandToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new AnchorBandToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: MIN_UPDATE_INTERVAL,
                transferStalenessMax: 1 days
            })
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 500_000,
            tokenGasLimit: 500_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _anchor() internal view returns (uint256) {
        return executor.attestationAnchorPrincipal(REMOTE_CHAIN);
    }

    function _net() internal view returns (uint256) {
        return executor.attestationNetPrincipal(REMOTE_CHAIN);
    }

    /// @dev ceil(settled * 10_000 / 12_000), the band-consistency floor, derived independently.
    function _ceilFloor(uint256 settled_) internal pure returns (uint256) {
        return (settled_ * 10_000 + 11_999) / 12_000;
    }

    function _propose(uint256 balance_) internal returns (uint256 proposalId) {
        proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
    }

    function _attest(uint256 balance_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(balance_);
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _supply(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    function _recall(uint256 amount_) internal {
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, amount_, 0, 0, address(0), 500_000);
    }

    function _expectBandRevertAt(uint256 proposed_, uint256 principal_) internal {
        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 proposalId = _propose(proposed_);
        vm.prank(APPROVER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorAttestationLib.AttestationOutsideAnchorBand.selector,
                REMOTE_CHAIN,
                principal_,
                proposed_,
                2_000
            )
        );
        executor.approveBalance(proposalId);
    }

    function _inflateToBandTop() internal {
        _supply(V);
        _attest(120e18);
    }

    function testRoundTripShouldNotRaiseAnchorAboveNetPrincipal() public {
        _inflateToBandTop();
        assertEq(_anchor(), V);
        assertEq(_net(), V);

        _recall(V);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e18, "0.2V residue");
        assertEq(_net(), 0, "net debited by the amount the dispatcher sent back");
        _supply(V);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18, "settled 1.2V");
        assertEq(_net(), V);
        assertEq(_anchor(), V, "anchor capped at net principal, not 7V/6");
        _expectBandRevertAt(130e18, V);
    }

    function testFiveRoundTripsShouldKeepAnchorFlat() public {
        _inflateToBandTop();
        for (uint256 i; i < 5; ++i) {
            _recall(V);
            _supply(V);
            assertLe(_anchor(), V, "anchor never exceeds V");
            assertLe(_net(), V, "net never exceeds V");
        }
        assertEq(_anchor(), V);
        _expectBandRevertAt(130e18, V);
    }

    function testHonestYieldResidueAfterFullRecallShouldStayAttestable() public {
        _supply(V);
        _attest(110e18);
        _recall(V);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 10e18);
        assertEq(_net(), 0);
        _supply(10e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e18);
        assertEq(_net(), 10e18, "net counts only the top-up");
        assertEq(_anchor(), _ceilFloor(20e18), "band-consistency floor fired: ceil(0.2V / 1.2)");
        assertGt(_anchor(), _net(), "floor lifted the anchor above the net cap");
        _attest(20e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e18);
    }

    function testPartialRecallThenResupplyShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(50e18);
        assertEq(_net(), 50e18);
        _supply(50e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18);
        assertEq(_net(), V);
        assertEq(_anchor(), V, "anchor capped at net principal");
        _expectBandRevertAt(130e18, V);
    }

    function testForceSetShouldRebaseNetPrincipal() public {
        uint256 arg = (uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) << 192) |
            (block.timestamp << 128) | 150e18;
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        assertEq(_anchor(), 150e18);
        assertEq(_net(), 150e18, "net rebased with the anchor");

        _supply(10e18);
        assertEq(_net(), 160e18);
        assertEq(_anchor(), 160e18, "anchor not capped down below the rebased value");
        _attest(170e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 170e18);
    }

    function testDustToZeroShouldResetNetPrincipal() public {
        _supply(5_000);
        assertEq(_net(), 5_000);
        assertEq(_anchor(), 5_000);
        _attest(0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(_anchor(), 0, "anchor reset");
        assertEq(_net(), 0, "net reset with the anchor");
    }

    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSent(uint256,bytes32,bytes32,uint256)");

    /// @dev Send `amount_` with auto-delivery off, so the OUTBOUND_TRANSFER never reaches the dispatcher.
    function _sendStuck(uint256 amount_) internal returns (bytes32 operationId) {
        router.setAutoDeliver(false);
        token.mint(address(executor), amount_);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        router.setAutoDeliver(true);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ASSET_SENT_TOPIC) {
                (, operationId, , ) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
                return operationId;
            }
        }
        revert("AssetSent not emitted");
    }

    function _forceResolve(bytes32 operationId_, bool credit_) internal {
        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId_, credit_);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId_, credit_);
    }

    function _assertCappedAtV() internal {
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 120e18, "settled 1.2V");
        assertEq(_net(), V, "net is the verifiably placed principal");
        assertEq(_anchor(), V, "anchor capped at net principal, not 7V/6");
        _expectBandRevertAt(130e18, V);
    }

    /// @notice The force-resolve credit (`applyForceResolveOutbound` site, `creditToSettled = true`) is capped.
    function testForceResolveCreditShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(V);
        bytes32 operationId = _sendStuck(V);
        _forceResolve(operationId, true);
        _assertCappedAtV();
    }

    /// @notice The late `TRANSFER_SETTLED` credit (`_applyLateCredit` site) after a DROP is capped.
    function testLateCreditShouldCapAnchorAtNetPrincipal() public {
        _inflateToBandTop();
        _recall(V);
        bytes32 operationId = _sendStuck(V);
        _forceResolve(operationId, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 20e18, "dropped, not yet credited");

        uint256 lateVersion = uint256(executor.lastRemoteStateVersion(REMOTE_CHAIN)) + 1;
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("late-settle"),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.TRANSFER_SETTLED,
                    abi.encode(operationId, V, V, lateVersion)
                ),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
        _assertCappedAtV();
    }

    /// @dev Recall `amount_`: the RETURN_REQUEST reaches the dispatcher, the RETURN_TRANSFER (tokens already
    ///      moved) is held, the attester pair approves `mid_`, then the RETURN_TRANSFER executes.
    function _recallWithInFlightApproval(uint256 amount_, uint256 mid_) internal {
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        uint256 idx = router.heldCount();
        _recall(amount_);
        router.deliverHeld(idx); // RETURN_REQUEST -> dispatcher, which sends RETURN_TRANSFER (held at idx + 1)
        assertEq(router.heldCount(), idx + 2, "RETURN_TRANSFER in flight");
        assertEq(dispatcher.trackedIdle(), 0, "dispatcher sent everything it had");
        if (mid_ != 0) _attest(mid_);
        router.deliverHeld(idx + 1);
        router.setAutoDeliver(true);
        router.setHoldTokenMessages(false);
    }

    /// @notice IL-8578 review: an approval that lowers `settled` while a recall is in flight must not leave
    ///         phantom units in `netPrincipal`; the debit is the amount the dispatcher declared it sent.
    function testInFlightApprovalShouldNotLeavePhantomNetPrincipal() public {
        _supply(V);
        _recallWithInFlightApproval(V, 80e18);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "bucket emptied");
        assertEq(_anchor(), 0, "anchor reached zero with the bucket");
        assertEq(dispatcher.trackedIdle(), 0, "nothing left remote");
        assertEq(_net(), 0, "net debited by the amount the dispatcher sent, not by the settled delta");
    }

    /// @notice IL-8578 review: three round trips with an in-flight approval leave no phantom principal, so the
    ///         TP-H-02 ratchet stays closed (the anchor is capped at V, 130e18 is outside the band).
    function testInFlightApprovalsShouldNotReopenRatchetAfterThreeRoundTrips() public {
        for (uint256 i; i < 3; ++i) {
            _supply(V);
            _recallWithInFlightApproval(V, 80e18);
            assertEq(_net(), 0, "no phantom net principal after a round trip");
        }

        _supply(V);
        _attest(120e18);
        _recall(V);
        _supply(V);
        assertEq(_net(), V, "net is the verifiably placed principal");
        assertEq(_anchor(), V, "anchor capped at net principal, not inflated");
        _expectBandRevertAt(130e18, V);
    }

    /// @notice Documented limitation (IL-8578 review): a realised loss stays in `netPrincipal` after the bucket
    ///         is emptied (supply 100, attest 90, recall 90 leaves 10). It is bounded by real losses and clears
    ///         on `forceSetSettled`; it is not an attacker-controlled amount.
    function testRealisedLossStaysInNetPrincipalKnownLimitation() public {
        _supply(V);
        _attest(90e18);
        // The remote position really lost 10%: the dispatcher holds only 90% of what was supplied.
        uint256 idle = dispatcher.trackedIdle();
        stdstore.target(address(dispatcher)).sig("trackedIdle()").checked_write((idle * 9) / 10);
        vm.prank(address(dispatcher));
        token.transfer(address(0xdead), V / 10);
        _recall(90e18);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0);
        assertEq(_anchor(), 0);
        assertEq(_net(), 10e18, "the lost 0.1V is still net principal");
    }
}
