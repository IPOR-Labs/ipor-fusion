// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipChainRescue} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CcipExecutorTransferLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorTransferLib.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CcipToken} from "./CcipLifecycleTest.t.sol";

/// @notice IL-8583 (Mario review): the manager's `cancelPendingReturn` is capped at
///         `MAX_CANCELLED_RECALLS_PER_CHAIN` unresolved cancelled recalls per chain, so an unmetered
///         recall -> cancel loop cannot fill the dispatcher's 64-slot response queue. The permissionless stale
///         path is not capped.
contract CcipCancelledRecallCapTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    uint256 internal constant STALENESS = 1 days;
    uint256 internal constant CAP = 4;

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

    /// @dev Deliver an authenticated `RETURN_REJECTED` for `operationId_` straight to the executor (resolves one
    ///      cancelled recall).
    function _deliverReject(bytes32 operationId_) private {
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256(abi.encode("reject", operationId_)),
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(CcipMsgType.RETURN_REJECTED, abi.encode(operationId_, uint8(1))),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    function _rescue(CcipChainRescue kind_, uint256 arg_) private {
        vm.prank(address(0xA11));
        uint256 rescueId = executor.scheduleChainRescue(kind_, REMOTE_CHAIN, arg_);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeChainRescue(rescueId, kind_, REMOTE_CHAIN, arg_);
    }

    function _live() private view returns (uint256) {
        uint64 head = dispatcher.responseQueueHead();
        return head == 0 ? 0 : uint256(dispatcher.responseQueueTail() - head) + 1;
    }

    /// @dev Open a recall of 1e18 and return its operation id.
    function _recall() private returns (bytes32) {
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 1e18, 0, 0, address(0), 500_000);
        return executor.activeReturn(REMOTE_CHAIN);
    }

    /// @dev Fund the dispatcher, then stall its sends so each `RETURN_TRANSFER` stays queued behind the head.
    function _fundAndStall() private {
        _fundRemoteIdle(100e18);
        router.setFailSend(address(dispatcher), true);
    }

    /// @dev `rounds_` recall -> manager cancel rounds; returns the cancelled operation ids.
    function _cancelRounds(uint256 rounds_) private returns (bytes32[] memory ids) {
        ids = new bytes32[](rounds_);
        for (uint256 i; i < rounds_; ++i) {
            ids[i] = _recall();
            executor.cancelPendingReturn(REMOTE_CHAIN);
        }
    }

    function _expectCap() private {
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorTransferLib.CancelledRecallCapReached.selector, REMOTE_CHAIN, CAP)
        );
    }

    function testShouldRefuseFifthManagerCancelWhileFourRecallsUnresolved() public {
        _fundAndStall();
        _cancelRounds(CAP);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP);
        _recall();
        _expectCap();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP, "count unchanged");
        assertTrue(executor.activeReturn(REMOTE_CHAIN) != bytes32(0), "recall still active");
    }

    function testShouldKeepHardCapUnreachableByRecallCancelLoop() public {
        _fundAndStall();
        assertEq(_live(), 0, "queue empty before the loop");
        // Mario's PoC: 64 recall -> cancel rounds in one block used to reach `ResponseQueueFull(64)`.
        for (uint256 i; i < 64; ++i) {
            _recall();
            try executor.cancelPendingReturn(REMOTE_CHAIN) {} catch {
                break;
            }
        }
        // 4 cancelled recalls + the active one: one queued answer each.
        assertLe(_live(), CAP + 1, "queue bounded by the cap");
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP);

        // A token delivery (TRANSFER_SETTLED) still fits.
        token.mint(address(executor), 5e18);
        uint256 before = _live();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 5e18, 0, address(0), 500_000);
        assertEq(_live(), before + 1, "TRANSFER_SETTLED queued");
        assertLe(_live(), CAP + 2);
    }

    function testShouldAllowStaleCancelAboveTheCap() public {
        _fundAndStall();
        _cancelRounds(CAP);
        _recall();
        vm.warp(block.timestamp + STALENESS + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP + 1, "stale path ignores the cap");
        assertEq(executor.activeReturn(REMOTE_CHAIN), bytes32(0));
        _recall();
        _expectCap();
        executor.cancelPendingReturn(REMOTE_CHAIN);
    }

    function testShouldReleaseCapWhenCancelledRecallResolves() public {
        _fundAndStall();
        bytes32[] memory ids = _cancelRounds(CAP);
        _recall();
        _expectCap();
        executor.cancelPendingReturn(REMOTE_CHAIN);

        _deliverReject(ids[0]);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP - 1);
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), CAP, "cap refilled");
    }

    function testShouldReleaseCapAfterAdvanceFrontierReset() public {
        _fundAndStall();
        _cancelRounds(CAP);
        // Drop every queued RETURN_TRANSFER with the timelocked skip valve so the frontier repair is legal.
        while (dispatcher.responseQueueHead() != 0) {
            uint64 head = dispatcher.responseQueueHead();
            vm.prank(address(0xA11));
            uint256 skipId = dispatcher.scheduleSkipStuckResponse(head);
            vm.warp(block.timestamp + 3 days);
            vm.prank(address(0xA11));
            dispatcher.executeSkipStuckResponse(skipId, head);
        }
        router.setFailSend(address(dispatcher), false);
        _rescue(CcipChainRescue.ADVANCE_FRONTIER, uint256(dispatcher.stateVersion()));
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "reset clears the count");
        _attestBalance(dispatcher.accountedBalance()); // lifts the frontier-repair block

        router.setFailSend(address(dispatcher), true); // keep the new recall open
        _recall();
        executor.cancelPendingReturn(REMOTE_CHAIN);
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 1, "manager cancel works again");
    }
}
