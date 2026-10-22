// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipToken} from "./CcipLifecycleTest.t.sol";

/// @notice IL-8635 (Ackee TP-L-07): a positive send can arrive with a ZERO destination amount after a CCIP 2.0
///         pool fee and decimal downscaling. An authenticated `RETURN_TRANSFER` with a zero or absent token entry
///         must finalize the recall with `received == 0` instead of being ignored.
contract CcipZeroAmountReturnTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant STALENESS = 1 days;

    MockCcipRouter internal router;
    CcipToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
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
            address(0xA11),
            address(0xB22),
            3 days
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

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: address(0xA11),
            rescueGuardian: address(0xB22),
            balanceProposer: address(this),
            balanceApprover: address(0xA33),
            rescueDelay: 3 days,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    function _attestBalance(uint256 balance_) private {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            balance_,
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            uint64(block.number == 0 ? 1 : block.number),
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _fundRemoteIdle(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    /// @dev Recall 60 of 100, hold the messages, deliver the request so the dispatcher debits its tracked idle and
    ///      dispatches the token-bearing `RETURN_TRANSFER` (held, index 1), then cancel it permissionlessly once stale.
    function _recallDispatchedThenStaleCancelled() private returns (bytes32 operationId) {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(0);
        assertEq(dispatcher.trackedIdle(), 40e18, "dispatcher debited its idle");
        assertEq(router.heldCount(), 2, "RETURN_TRANSFER dispatched");
        vm.warp(block.timestamp + STALENESS + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
    }

    event ReturnBelowMinimumCredited(uint256 chainId, bytes32 operationId, uint256 received, uint256 minimum);
    event ReturnFinalized(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 received, uint256 debitedSD);
    event LateReturnFinalized(uint256 chainId, bytes32 operationId, uint256 sentSD, uint256 received, uint256 debitedSD);
    event InboundMessageIgnored(uint256 chainId, uint8 messageType, bytes32 reason);

    /// @dev Recall 60 of 100 with a 50 floor; the request is delivered so the dispatcher dispatches its (held)
    ///      real `RETURN_TRANSFER` at index 1.
    function _recall() private returns (bytes32 operationId) {
        _fundRemoteIdle(100e18);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 50e18, 0, address(0), 500_000);
        operationId = executor.activeReturn(REMOTE_CHAIN);
        router.deliverHeld(0);
        assertEq(router.heldCount(), 2, "RETURN_TRANSFER dispatched");
    }

    function _deliverReturn(bytes32 operationId_, CcipClient.EVMTokenAmount[] memory amounts_) private {
        _deliverReturnAt(operationId_, amounts_, executor.lastRemoteStateVersion(REMOTE_CHAIN) + 1);
    }

    function _deliverReturnAt(bytes32 operationId_, CcipClient.EVMTokenAmount[] memory amounts_, uint64 version)
        private
    {
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("return", operationId_, version)),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.RETURN_TRANSFER, abi.encode(operationId_, uint256(60e18), uint256(40e18), version)
                ),
                destTokenAmounts: amounts_
            })
        );
    }

    function _zeroEntry() private view returns (CcipClient.EVMTokenAmount[] memory amounts) {
        amounts = new CcipClient.EVMTokenAmount[](1);
        amounts[0] = CcipClient.EVMTokenAmount({token: address(token), amount: 0});
    }

    function _assertFinalizedWithZero() private view {
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0), "activeReturn cleared");
        assertEq(executor.idleLedger(), 0, "idle unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "settled debited by sentSD");
        assertEq(executor.getBalance(), 40e18, "NAV live, slot released");
    }

    function testShouldFinalizeReturnWithZeroDeliveredAmount() public {
        bytes32 operationId = _recall();
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);
        uint64 receiptBefore = executor.lastValueMovingReceiptAt(REMOTE_CHAIN);
        vm.warp(block.timestamp + 1 hours);
        vm.expectEmit(address(executor));
        emit ReturnBelowMinimumCredited(REMOTE_CHAIN, operationId, 0, 50e18);
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 60e18, 0, 60e18);
        _deliverReturn(operationId, _zeroEntry());
        _assertFinalizedWithZero();
        // The zero path is value-moving (the dispatcher debited sentSD): epoch bump + IL-8604 receipt stamp.
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore + 1, "epoch bumped on zero return");
        assertGt(block.timestamp, receiptBefore);
        assertEq(executor.lastValueMovingReceiptAt(REMOTE_CHAIN), uint64(block.timestamp), "receipt stamped");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1, "version consumed once");
    }

    function testShouldFinalizeReturnWithAbsentTokenEntry() public {
        bytes32 operationId = _recall();
        vm.expectEmit(address(executor));
        emit ReturnFinalized(REMOTE_CHAIN, operationId, 60e18, 0, 60e18);
        _deliverReturn(operationId, new CcipClient.EVMTokenAmount[](0));
        _assertFinalizedWithZero();
    }

    function testShouldIgnoreSecondDeliveryOfZeroAmountReturn() public {
        bytes32 operationId = _recall();
        _deliverReturn(operationId, _zeroEntry());
        uint64 versionAfter = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        // Replay of the same message: the receiver's replay guard rejects it before the handler runs.
        vm.expectRevert(
            abi.encodeWithSignature(
                "CcipMessageAlreadyProcessed(bytes32)", keccak256(abi.encode("return", operationId, versionAfter))
            )
        );
        _deliverReturnAt(operationId, _zeroEntry(), versionAfter);
        // A distinct message for the already finalized recall is ignored as unknown and moves nothing.
        vm.expectEmit(address(executor));
        emit InboundMessageIgnored(REMOTE_CHAIN, uint8(CcipMsgType.RETURN_TRANSFER), "unknown");
        _deliverReturnAt(operationId, _zeroEntry(), versionAfter - 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "not debited twice");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionAfter, "version not consumed again");
        assertEq(executor.idleLedger(), 0);
    }

    function testShouldStillIgnoreWrongTokenAndMultipleEntries() public {
        bytes32 operationId = _recall();
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        CcipClient.EVMTokenAmount[] memory wrong = _zeroEntry();
        wrong[0].token = address(0xBEEF);
        vm.expectEmit(address(executor));
        emit InboundMessageIgnored(REMOTE_CHAIN, uint8(CcipMsgType.RETURN_TRANSFER), "token");
        _deliverReturn(operationId, wrong);
        assertEq(executor.activeReturn(REMOTE_CHAIN), operationId, "recall still open");
        // pre-existing behaviour: the ignored shape still consumes the state version
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1, "version consumed by ignored");

        CcipClient.EVMTokenAmount[] memory two = new CcipClient.EVMTokenAmount[](2);
        two[0] = _zeroEntry()[0];
        two[1] = _zeroEntry()[0];
        vm.expectEmit(address(executor));
        emit InboundMessageIgnored(REMOTE_CHAIN, uint8(CcipMsgType.RETURN_TRANSFER), "token");
        _deliverReturn(operationId, two);
        assertEq(executor.activeReturn(REMOTE_CHAIN), operationId, "recall still open");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 2, "version consumed by ignored");
    }

    function testShouldKeepNonZeroDeliveryUnchanged() public {
        bytes32 operationId = _recall();
        router.deliverHeld(1);
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
        assertEq(executor.idleLedger(), 60e18, "credited");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18);
        // a distinct synthetic message (fresh version) consumes the version and is ignored as unknown
        vm.expectEmit(address(executor));
        emit InboundMessageIgnored(REMOTE_CHAIN, uint8(CcipMsgType.RETURN_TRANSFER), "unknown");
        _deliverReturn(operationId, _zeroEntry());
        assertEq(executor.idleLedger(), 60e18);
    }

    function testShouldResolveCancelledRecallClockOnZeroAmountFinalization() public {
        uint256 requestedAt = block.timestamp + 1;
        bytes32 operationId = _recall();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), requestedAt, "clock carried over");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1);
        vm.expectEmit(address(executor));
        emit LateReturnFinalized(REMOTE_CHAIN, operationId, 60e18, 0, 60e18);
        _deliverReturn(operationId, _zeroEntry());
        assertEq(executor.cancelledRecallPendingAt(REMOTE_CHAIN), 0, "clock cleared");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18);
        assertEq(executor.idleLedger(), 0);
    }

    function testShouldFinalizeLateZeroAmountReturnAfterPermissionlessCancel() public {
        bytes32 operationId = _recallDispatchedThenStaleCancelled();
        vm.expectEmit(address(executor));
        emit LateReturnFinalized(REMOTE_CHAIN, operationId, 60e18, 0, 60e18);
        _deliverReturn(operationId, _zeroEntry());
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "cancelled recall resolved");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "settled debited by sentSD");
        assertEq(executor.idleLedger(), 0);
    }
}
