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

/// @notice IL-8635 (Ackee TP-L-07), OUTBOUND direction: a positive executor-to-dispatcher send can arrive with a ZERO
///         destination amount after a CCIP 2.0 pool fee plus decimal downscaling (modelled here by a 100% pool
///         haircut in the router mock). The dispatcher must settle it as a zero credit instead of reverting, so
///         the executor closes the outbound and reports the loss.
contract CcipZeroAmountOutboundTest is Test {
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

    event SettledCreditShortfall(uint256 chainId, bytes32 operationId, uint256 amountSD, uint256 receivedSD);
    event SettledBelowMinDelivered(uint256 chainId, bytes32 operationId, uint256 minDeliveredSD, uint256 receivedSD);
    event AssetSettled(uint256 chainId, bytes32 operationId, uint256 amountSD);
    event InboundSettled(bytes32 operationId, uint256 amount, uint64 version);

    function _supply(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000);
    }

    /// @dev Sends with a 100% pool haircut and a held (not yet executed) message; returns the operation id.
    function _zeroSendHeld(uint256 amount_, uint256 minDelivered_) private returns (bytes32 operationId) {
        router.setPoolHaircutBps(10_000);
        router.setAutoDeliver(false);
        router.setHoldTokenMessages(true);
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 500_000, minDelivered_);
        assertEq(router.heldCount(), 1, "outbound held");
        (, bytes memory body) = CcipMessages.decode(router.heldData(0));
        operationId = abi.decode(body, (bytes32));
        router.setAutoDeliver(true); // so the TRANSFER_SETTLED response reaches the executor
        assertEq(dispatcher.trackedIdle(), 0);
    }

    function _outboundMessage(bytes32 operationId_, bytes32 messageId_, CcipClient.EVMTokenAmount[] memory amounts_)
        private
        view
        returns (CcipClient.Any2EVMMessage memory)
    {
        return CcipClient.Any2EVMMessage({
            messageId: messageId_,
            sourceChainSelector: EXECUTOR_SELECTOR,
            sender: abi.encode(address(executor)),
            data: CcipMessages.encode(CcipMsgType.OUTBOUND_TRANSFER, abi.encode(operationId_)),
            destTokenAmounts: amounts_
        });
    }

    function _entry(address token_, uint256 amount_) private pure returns (CcipClient.EVMTokenAmount memory) {
        return CcipClient.EVMTokenAmount({token: token_, amount: amount_});
    }

    /// @dev The router mock drops a zero-amount token entry on a late delivery, so the held outbound is delivered
    ///      as the OffRamp would: one ASSET entry with amount 0.
    function _deliverZeroHeld(bytes32 operationId_) private {
        CcipClient.EVMTokenAmount[] memory zero = new CcipClient.EVMTokenAmount[](1);
        zero[0] = _entry(address(token), 0);
        CcipClient.Any2EVMMessage memory message = _outboundMessage(operationId_, keccak256("held"), zero);
        message.data = router.heldData(0);
        vm.prank(address(router));
        dispatcher.ccipReceive(message);
    }

    function testShouldSettleZeroDeliveredOutboundAsZeroCredit() public {
        bytes32 operationId = _zeroSendHeld(100e18, 0);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 100e18, "in flight");
        uint64 versionBefore = dispatcher.stateVersion();
        uint64 epochBefore = executor.accountingEpoch(REMOTE_CHAIN);

        vm.expectEmit(address(executor));
        emit SettledCreditShortfall(REMOTE_CHAIN, operationId, 100e18, 0);
        vm.expectEmit(address(executor));
        emit AssetSettled(REMOTE_CHAIN, operationId, 0);
        // The response is delivered inside the dispatcher's queue call, so the executor's events come first.
        vm.expectEmit(address(dispatcher));
        emit InboundSettled(operationId, 0, versionBefore + 1);
        _deliverZeroHeld(operationId);

        assertEq(dispatcher.stateVersion(), versionBefore + 1, "version bumped once");
        assertTrue(dispatcher.processedOperation(operationId), "processed");
        assertEq(dispatcher.trackedIdle(), 0, "nothing credited");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound closed");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "zero credit");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1, "executor consumed the version");
        assertEq(executor.accountingEpoch(REMOTE_CHAIN), epochBefore + 1, "epoch bumped");

        // The outbound no longer ages: NAV stays live past the staleness window.
        vm.warp(block.timestamp + STALENESS + 1);
        assertEq(executor.getBalance(), 0, "getBalance does not revert");
    }

    function testShouldKeepLaneUsableAfterZeroDeliveredOutbound() public {
        bytes32 operationId = _zeroSendHeld(100e18, 0);
        _deliverZeroHeld(operationId);
        router.setPoolHaircutBps(0);
        router.setHoldTokenMessages(false);
        vm.warp(block.timestamp + STALENESS + 1);
        uint64 versionBefore = dispatcher.stateVersion();

        _supply(50e18);
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "contiguous version");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 50e18);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        _attestBalance(dispatcher.accountedBalance());
        assertEq(executor.getBalance(), 50e18, "NAV live and attested");
    }

    function testShouldReportBelowMinDeliveredOnZeroDeliveredOutbound() public {
        bytes32 operationId = _zeroSendHeld(100e18, 40e18);
        vm.expectEmit(address(executor));
        emit SettledCreditShortfall(REMOTE_CHAIN, operationId, 100e18, 0);
        vm.expectEmit(address(executor));
        emit SettledBelowMinDelivered(REMOTE_CHAIN, operationId, 40e18, 0);
        _deliverZeroHeld(operationId);
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "outbound closed");
    }

    function testShouldStillRejectMalformedOutboundTokenShapes() public {
        bytes32 operationId = keccak256("op");
        CcipClient.EVMTokenAmount[] memory none = new CcipClient.EVMTokenAmount[](0);
        vm.prank(address(router));
        vm.expectRevert(CcipCrosschainDispatcher.InvalidTokenDelivery.selector);
        dispatcher.ccipReceive(_outboundMessage(operationId, keccak256("m1"), none));

        CcipClient.EVMTokenAmount[] memory foreign = new CcipClient.EVMTokenAmount[](1);
        foreign[0] = _entry(address(0xBEEF), 1e18);
        vm.prank(address(router));
        vm.expectRevert(CcipCrosschainDispatcher.InvalidTokenDelivery.selector);
        dispatcher.ccipReceive(_outboundMessage(operationId, keccak256("m2"), foreign));

        CcipClient.EVMTokenAmount[] memory zeroForeign = new CcipClient.EVMTokenAmount[](1);
        zeroForeign[0] = _entry(address(0xBEEF), 0);
        vm.prank(address(router));
        vm.expectRevert(CcipCrosschainDispatcher.InvalidTokenDelivery.selector);
        dispatcher.ccipReceive(_outboundMessage(operationId, keccak256("m3"), zeroForeign));

        CcipClient.EVMTokenAmount[] memory two = new CcipClient.EVMTokenAmount[](2);
        two[0] = _entry(address(token), 0);
        two[1] = _entry(address(token), 0);
        vm.prank(address(router));
        vm.expectRevert(CcipCrosschainDispatcher.InvalidTokenDelivery.selector);
        dispatcher.ccipReceive(_outboundMessage(operationId, keccak256("m4"), two));

        assertFalse(dispatcher.processedOperation(operationId), "nothing consumed");
    }

    function testShouldRejectSecondMessageForSameZeroDeliveredOperation() public {
        bytes32 operationId = _zeroSendHeld(100e18, 0);
        _deliverZeroHeld(operationId);
        uint64 versionAfter = dispatcher.stateVersion();

        CcipClient.EVMTokenAmount[] memory zero = new CcipClient.EVMTokenAmount[](1);
        zero[0] = _entry(address(token), 0);
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSignature("CcipMessageAlreadyProcessed(bytes32)", operationId));
        dispatcher.ccipReceive(_outboundMessage(operationId, keccak256("again"), zero));
        assertEq(dispatcher.stateVersion(), versionAfter, "version not bumped again");
    }
}
