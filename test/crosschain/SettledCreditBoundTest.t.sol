// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";

/// @title SettledCreditBoundTest
/// @notice Regression cover for `settled_credit_not_bounded_by_outbound_amount` (IL-8060): the
///         `TRANSFER_SETTLED` handler debited `outboundInFlight` by the locally recorded transfer amount
///         but credited `settledRemoteBalance` by the peer-supplied `received` figure with no relation
///         asserted, on the CCIP fresh-settle and force-resolved late-credit paths and on the mirror
///         Stargate settle path. A forged receipt could inflate NAV by an arbitrary multiple. The fix
///         clamps `credited = min(received, recorded amount)` on all three sites and emits
///         `SettledCreditClamped` (never reverts) when the clamp fires.
contract CcipSettledCreditBoundToken is ERC20 {
    constructor() ERC20("USD", "USD") {}

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @notice CCIP half. Uses the `_deploy(18, 6)` shape from `CcipAuditRemediationTest` (rate 1e12) so a
///         unit slip (comparing shared-decimal `received` against a local-decimal figure) cannot pass by
///         accident — assessment 1.7.
contract CcipSettledCreditBoundTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant RESCUE_GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);

    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSent(uint256,bytes32,bytes32,uint256)");
    bytes32 internal constant SETTLED_CREDIT_CLAMPED_TOPIC =
        keccak256("SettledCreditClamped(uint256,bytes32,uint256,uint256)");
    bytes32 internal constant ASSET_SETTLED_TOPIC = keccak256("AssetSettled(uint256,bytes32,uint256)");
    bytes32 internal constant INBOUND_MESSAGE_IGNORED_TOPIC = keccak256("InboundMessageIgnored(uint256,uint8,bytes32)");

    MockCcipRouter internal router;
    CcipSettledCreditBoundToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new CcipSettledCreditBoundToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            6,
            _safety()
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
            6,
            block.chainid,
            back,
            RESCUE_ADMIN,
            RESCUE_GUARDIAN,
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
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: RESCUE_GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            });
    }

    function _attest(uint256 balanceSD_) private {
        vm.warp(block.timestamp + 1); // observation must postdate the last value-moving receipt
        uint256 proposalId = executor.proposeBalance(
            REMOTE_CHAIN,
            _toLD(balanceSD_),
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            1,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days),
            dispatcher.trackedPositionSetHash()
        );
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _toLD(uint256 amountSD_) private view returns (uint256) {
        return amountSD_ * executor.DECIMAL_CONVERSION_RATE();
    }

    /// @dev Sends `100e18` (18-decimal local asset) out, which records `transfer.amount = 100e6` shared
    ///      decimals. Returns the operation id captured off the `AssetSent` log (no indexed params).
    function _sendAndCaptureOperationId() private returns (bytes32 operationId) {
        token.mint(address(executor), 100e18);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(executor) && logs[i].topics[0] == ASSET_SENT_TOPIC) {
                (, operationId, , ) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
            }
        }
        assertTrue(operationId != bytes32(0), "operation id captured");
    }

    function _deliverSettled(
        bytes32 messageId_,
        bytes32 operationId_,
        uint256 received_,
        uint64 stateVersion_
    ) private {
        vm.prank(address(router));
        executor.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: messageId_,
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: CcipMessages.encode(
                    CcipMsgType.TRANSFER_SETTLED,
                    abi.encode(operationId_, received_, received_, stateVersion_)
                ),
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    /// @dev Returns the number of `SettledCreditClamped` logs emitted by the executor, and — if exactly
    ///      one exists — its decoded fields.
    function _countClampLogs(
        Vm.Log[] memory logs_
    ) private view returns (uint256 count, uint256 chainId, bytes32 operationId, uint256 reported, uint256 credited) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == SETTLED_CREDIT_CLAMPED_TOPIC) {
                ++count;
                (chainId, operationId, reported, credited) = abi.decode(
                    logs_[i].data,
                    (uint256, bytes32, uint256, uint256)
                );
            }
        }
    }

    function _assetSettledCredited(Vm.Log[] memory logs_) private view returns (uint256 count, uint256 credited) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == ASSET_SETTLED_TOPIC) {
                ++count;
                // AssetSettled(uint256 chainId, bytes32 operationId, uint256 received) — three words.
                (, , credited) = abi.decode(logs_[i].data, (uint256, bytes32, uint256));
            }
        }
    }

    function _ignoreReason(Vm.Log[] memory logs_) private view returns (bytes32 reason, uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == INBOUND_MESSAGE_IGNORED_TOPIC) {
                ++count;
                (, , reason) = abi.decode(logs_[i].data, (uint256, uint8, bytes32));
            }
        }
    }

    // =====================================================================
    // Vulnerable paths — must fail without the fix
    // =====================================================================

    function testFreshSettleCreditIsBoundedByOutboundAmount() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.recordLogs();
        _deliverSettled(keccak256("forged-fresh-settle"), operationId, 100_000e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight debited by the recorded amount");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "credit bounded to the recorded amount");

        (uint256 clampCount, uint256 chainId, bytes32 opId, uint256 reported, uint256 credited) = _countClampLogs(logs);
        assertEq(clampCount, 1, "exactly one clamp event");
        assertEq(chainId, REMOTE_CHAIN);
        assertEq(opId, operationId);
        assertEq(reported, 100_000e6, "reported figure is the forged value");
        assertEq(credited, 100e6, "credited figure is the recorded outbound amount");

        (uint256 assetSettledCount, uint256 assetSettledCredited) = _assetSettledCredited(logs);
        assertEq(assetSettledCount, 1);
        assertEq(assetSettledCredited, 100e6, "AssetSettled reports the credited (bounded) amount");

        _attest(100e6);
        assertEq(executor.getBalanceByChain(REMOTE_CHAIN), 100e18, "NAV priced at the true principal");
    }

    function testLateCreditIsBoundedByOutboundAmount() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        assertEq(executor.getBalance(), 0, "dropped transfer no longer freezes or inflates NAV");

        vm.recordLogs();
        _deliverSettled(keccak256("forged-late-settle"), operationId, 100_000e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "late credit bounded to the recorded amount");
        (uint256 clampCount, , , uint256 reported, uint256 credited) = _countClampLogs(logs);
        assertEq(clampCount, 1, "exactly one clamp event on the late path");
        assertEq(reported, 100_000e6);
        assertEq(credited, 100e6);

        // A second message for the same operation (new messageId — this is a force-resolved transfer, so
        // it is NOT the "duplicate" branch, which only fires for a non-force-resolved settled transfer;
        // see `testClampedSettleStillResolvesRecordAndStaleness` for that case). `remoteCreditAccounted`
        // is already true, so this credits nothing: it must not move `settled` and must not emit a clamp
        // event (nothing was credited, so nothing to bound).
        vm.recordLogs();
        _deliverSettled(keccak256("forged-late-settle-second-message"), operationId, 100_000e6, 2);
        Vm.Log[] memory secondLogs = vm.getRecordedLogs();
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "second late message does not re-credit settled");
        (uint256 secondClampCount, , , , ) = _countClampLogs(secondLogs);
        assertEq(secondClampCount, 0, "no clamp when nothing is credited");
        (, uint256 ignoredCount) = _ignoreReason(secondLogs);
        assertEq(ignoredCount, 1, "ignored as credited: forceResolved is true, credit already accounted");
    }

    /// @dev Force-resolve WITH credit, then the honest late TRANSFER_SETTLED: nothing more to credit, so the
    ///      message is ignored with reason "credited" (no second `AssetSettled`), yet its version is consumed.
    function testShouldIgnoreLateSettleAsCreditedAfterCreditingForceResolve() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, true);
        vm.warp(block.timestamp + 3 days);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, true);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "force-resolve credited settled");
        uint64 versionBefore = executor.lastRemoteStateVersion(REMOTE_CHAIN);

        vm.recordLogs();
        _deliverSettled(keccak256("honest-late-settle-after-credit"), operationId, 100e6, versionBefore + 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 assetSettledCount, ) = _assetSettledCredited(logs);
        assertEq(assetSettledCount, 0, "no AssetSettled echo for an already-credited transfer");
        (bytes32 reason, uint256 ignoredCount) = _ignoreReason(logs);
        assertEq(ignoredCount, 1, "exactly one InboundMessageIgnored");
        assertEq(reason, bytes32("credited"), "distinct reason from duplicate");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "settled unchanged by the late message");
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), versionBefore + 1, "state version consumed");
    }

    /// @dev Control: force-resolve WITHOUT credit, then the late TRANSFER_SETTLED credits once and emits
    ///      `AssetSettled` exactly once, with no ignore.
    function testShouldCreditOnceAndEmitAssetSettledOnLateSettleAfterNonCreditingForceResolve() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "non-crediting force-resolve credits nothing");

        vm.recordLogs();
        _deliverSettled(keccak256("honest-late-settle-control"), operationId, 100e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 assetSettledCount, uint256 assetSettledCredited) = _assetSettledCredited(logs);
        assertEq(assetSettledCount, 1, "AssetSettled emitted once");
        assertEq(assetSettledCredited, 100e6);
        (, uint256 ignoredCount) = _ignoreReason(logs);
        assertEq(ignoredCount, 0, "applied, not ignored");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "credited once");
    }

    // =====================================================================
    // Controls — must pass both before and after the fix
    // =====================================================================

    function testHonestShortfallSettleIsCreditedAsReported() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.recordLogs();
        _deliverSettled(keccak256("honest-shortfall"), operationId, 99e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 99e6, "honest shortfall credited as reported");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0);
        (uint256 clampCount, , , , ) = _countClampLogs(logs);
        assertEq(clampCount, 0, "no clamp on a legitimate route-fee shortfall");
        (uint256 assetSettledCount, uint256 assetSettledCredited) = _assetSettledCredited(logs);
        assertEq(assetSettledCount, 1);
        assertEq(assetSettledCredited, 99e6);
    }

    function testHonestDispatcherSettlementNeverClamps() public {
        // Default auto-deliver: the real dispatcher answers TRANSFER_SETTLED synchronously.
        token.mint(address(executor), 100e18);
        vm.recordLogs();
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 500_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "end-to-end settlement credited in full");
        assertEq(dispatcher.trackedIdle(), 100e6, "dispatcher physically holds the bridged principal");
        (uint256 clampCount, , , , ) = _countClampLogs(logs);
        assertEq(clampCount, 0, "the clamp never fires on the honest production lane");
    }

    function testLateCreditShortfallIsCreditedAsReported() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();

        vm.prank(RESCUE_ADMIN);
        uint256 rescueId = executor.scheduleForceResolveOutbound(operationId, false);
        vm.warp(block.timestamp + 3 days);
        vm.prank(RESCUE_ADMIN);
        executor.executeForceResolveOutbound(rescueId, operationId, false);

        vm.recordLogs();
        _deliverSettled(keccak256("honest-late-shortfall"), operationId, 99e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 99e6, "late honest shortfall credited as reported");
        (uint256 clampCount, , , , ) = _countClampLogs(logs);
        assertEq(clampCount, 0, "no clamp on a legitimate late shortfall");
    }

    /// @notice Guards the CCIP library move: every pre-existing side effect of the fresh-settle branch
    ///         (record resolution, staleness-slot release, epoch bump enabling the next attestation) must
    ///         still run when the clamp fires, and a replay of the same message must still be ignored as a
    ///         duplicate. Deliberately does not assert on `settled` — that is the job of the other tests —
    ///         so this test stays a pure refactor guard, not a second clamp assertion.
    function testClampedSettleStillResolvesRecordAndStaleness() public {
        router.setAutoDeliver(false);
        bytes32 operationId = _sendAndCaptureOperationId();
        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 1, "slot armed on send");
        assertTrue(executor.oldestPendingAt(REMOTE_CHAIN) != 0, "staleness clock armed on send");

        _deliverSettled(keccak256("clamped-settle-refactor-guard"), operationId, 100_000e6, 1);

        assertEq(executor.pendingTransferCount(REMOTE_CHAIN), 0, "staleness slot released on settle");
        assertEq(executor.oldestPendingAt(REMOTE_CHAIN), 0, "no armed slot remains");

        // The record is resolved and the staleness clock disarmed, so a fresh approved observation must
        // not revert TransferStale even long after the (now irrelevant) transfer-staleness window.
        vm.warp(block.timestamp + 1 days + 1);
        _attest(100e6);
        executor.getBalanceByChain(REMOTE_CHAIN);

        // A second, identical receipt (new messageId) must be ignored as a duplicate, not re-applied.
        vm.recordLogs();
        _deliverSettled(keccak256("clamped-settle-refactor-guard-replay"), operationId, 100_000e6, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bytes32 reason, uint256 ignoredCount) = _ignoreReason(logs);
        assertEq(ignoredCount, 1);
        assertEq(reason, bytes32("duplicate"));
    }
}

/// @notice Stargate half. `CrosschainTestBase` already wires a `StargateCrosschainExecutor` with a
///         6-decimal asset (shared-decimal shape by construction), so `_sendAsset`/`_deliverTransferSettled`
///         operate directly in shared decimals.
contract StargateSettledCreditBoundTest is CrosschainTestBase {
    bytes32 internal constant SETTLED_CREDIT_CLAMPED_TOPIC =
        keccak256("SettledCreditClamped(uint256,bytes32,uint256,uint256)");

    function setUp() public {
        _baseSetUp();
    }

    function _countClampLogs(
        Vm.Log[] memory logs_
    ) private view returns (uint256 count, uint256 chainId, bytes32 transferId, uint256 reported, uint256 credited) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].emitter == address(executor) && logs_[i].topics[0] == SETTLED_CREDIT_CLAMPED_TOPIC) {
                ++count;
                (chainId, transferId, reported, credited) = abi.decode(
                    logs_[i].data,
                    (uint256, bytes32, uint256, uint256)
                );
            }
        }
    }

    function testTransferSettledCreditIsBoundedByOutboundAmount() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid, uint256 amountSD) = _sendAsset(100e6, 0);
        assertEq(amountSD, 100e6, "recorded outbound amount");

        vm.recordLogs();
        _deliverTransferSettled(transferId, guid, 100_000e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e6, "credit bounded to the recorded amount");
        assertEq(executor.outboundInFlight(REMOTE_CHAIN), 0, "in-flight debited by the recorded amount");
        assertEq(executor.acknowledgedRemoteStateVersion(REMOTE_CHAIN), 1, "frontier still advances");

        (uint256 clampCount, uint256 chainId, bytes32 id, uint256 reported, uint256 credited) = _countClampLogs(logs);
        assertEq(clampCount, 1, "exactly one clamp event");
        assertEq(chainId, REMOTE_CHAIN);
        assertEq(id, transferId);
        assertEq(reported, 100_000e6, "reported figure is the forged value");
        assertEq(credited, 100e6, "credited figure is the recorded outbound amount");
    }

    event TransferSettledInbound(
        uint256 srcChainId,
        bytes32 transferId,
        bytes32 guid,
        uint256 sentSD,
        uint256 creditedSD,
        uint64 stateVersion
    );
    event SettledCreditClamped(uint256 srcChainId, bytes32 transferId, uint256 reportedSD, uint256 creditedSD);

    function testShouldEmitSentAndCreditedOnExactSettle() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);

        vm.expectEmit(address(executor));
        emit TransferSettledInbound(REMOTE_CHAIN, transferId, guid, 100e6, 100e6, 1);
        _deliverTransferSettled(transferId, guid, 100e6, 1);
    }

    function testShouldEmitShortfallWithoutClampOnUnderReport() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);

        vm.recordLogs();
        vm.expectEmit(address(executor));
        emit TransferSettledInbound(REMOTE_CHAIN, transferId, guid, 100e6, 90e6, 1);
        _deliverTransferSettled(transferId, guid, 90e6, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        (uint256 clampCount, , , , ) = _countClampLogs(logs);
        assertEq(clampCount, 0, "under-report is not a clamp");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 90e6, "credited the reported amount");
    }

    function testShouldEmitClampThenSettledWithClampedCreditOnOverReport() public {
        _readyDispatcher();
        (bytes32 transferId, bytes32 guid, ) = _sendAsset(100e6, 0);

        vm.expectEmit(address(executor));
        emit SettledCreditClamped(REMOTE_CHAIN, transferId, 1000e6, 100e6);
        vm.expectEmit(address(executor));
        emit TransferSettledInbound(REMOTE_CHAIN, transferId, guid, 100e6, 100e6, 1);
        _deliverTransferSettled(transferId, guid, 1000e6, 1);
    }
}
