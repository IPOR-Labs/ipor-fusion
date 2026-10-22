// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {CcipExecutorFixture, CcipFixtureToken} from "test/crosschain/CcipExecutorFixture.sol";
import {CcipCrosschainExecutor} from "contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorCommandLib} from "contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipMessages, CcipMsgType} from "contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CrosschainErrors} from "contracts/crosschain/lib/CrosschainErrors.sol";
import {MockCcipRouter} from "test/crosschain/mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "test/crosschain/mocks/MockCcipRouteValidator.sol";

/// @notice Tracked vault stand-in whose position value is set directly (one share, `assets` worth of the asset).
contract FixedValueVault {
    address public immutable asset;
    uint256 public assets;

    constructor(address asset_) {
        asset = asset_;
    }

    function setAssets(uint256 assets_) external {
        assets = assets_;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1;
    }

    function convertToAssets(uint256) external view returns (uint256) {
        return assets;
    }
}

/// @title CcipQueuedReturnReportedBalanceTest
/// @notice IL-8768 (BugPoCer #33): a response about to be queued must report the remote balance AFTER every token
///         response queued ahead of it, not including them. The executor applies responses strictly by version, so
///         an earlier queued RETURN_TRANSFER is debited from `settled` first; counting its tokens again in the
///         later response left a phantom residual anchor once that response emptied `settled`.
///         `observation()` / `accountedBalance()` keep counting queued tokens (audit M-8).
contract CcipQueuedReturnReportedBalanceTest is CcipExecutorFixture {
    FixedValueVault internal vault;

    function setUp() public {
        vm.warp(365 days);
        // Same wiring as `_fixtureSetUp`, but the dispatcher tracks one vault so an honest residual can exist.
        router = new MockCcipRouter();
        token = new CcipFixtureToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _testSafety()
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            _route(EXECUTOR_SELECTOR, address(executor)),
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vault = new FixedValueVault(address(token));
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        vm.prank(factory);
        dispatcher.configureVaults(vaults, true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 500_000,
                tokenGasLimit: 500_000,
                maxFee: 0,
                enabled: true
            });
    }

    function _testSafety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: BALANCE_STALENESS_MAX,
                bigChangeBps: 2_000,
                minUpdateInterval: MIN_UPDATE_INTERVAL,
                transferStalenessMax: 1 days
            });
    }

    /// @dev Bridge 100, stall the dispatcher lane, queue R1 (40) and let it go stale + cancel on the executor,
    ///      then queue R2 (60). Returns R2's reported balance (shared decimals == 18 here).
    function _queueCancelledR1ThenR2() private returns (uint256 reportedR2) {
        _bridge(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 0, 0, address(0), 500_000);
        assertEq(dispatcher.queuedTokenAmount(), 40e18, "R1 tokens queued");
        vm.warp(block.timestamp + 1 days + 1);
        executor.cancelStalePendingReturn(REMOTE_CHAIN);
    }

    function _queuedTailReported() private view returns (uint256 reported, uint64 version) {
        (bytes memory envelope, , ) = dispatcher.queuedResponse(dispatcher.responseQueueTail());
        (CcipMsgType msgType, bytes memory inner) = CcipMessages.decode(envelope);
        assertEq(uint8(msgType), uint8(CcipMsgType.RETURN_TRANSFER), "tail is a RETURN_TRANSFER");
        (, , reported, version) = abi.decode(inner, (bytes32, uint256, uint256, uint64));
    }

    function testReturnBehindAQueuedReturnShouldNotCountItInTheReportedBalance() public {
        _queueCancelledR1ThenR2();
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 0, 0, address(0), 500_000);
        assertEq(dispatcher.trackedIdle(), 0, "dispatcher idle drained");
        assertEq(dispatcher.queuedTokenAmount(), 100e18, "both returns queued");

        (uint256 reported, uint64 version) = _queuedTailReported();
        assertEq(version, 3, "R2 versioned 3");
        assertEq(reported, 0, "R2 reports the balance after R1 landed, not R1 again");

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse(2);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 3, "both returns applied");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled fully debited");
        assertEq(executor.idleLedger(), 100e18, "all 100 back home");
        assertEq(dispatcher.accountedBalance(), 0, "remote holds nothing");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 0, "no phantom residual anchor");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(48e18);
        vm.prank(APPROVER);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnanchoredAttestation.selector, REMOTE_CHAIN, 48e18));
        executor.approveBalance(pid);
        assertEq(executor.getBalanceUnchecked(), 100e18, "NAV stays at the true total");
    }

    function testHonestResidualBehindAQueuedReturnShouldStillAnchor() public {
        _queueCancelledR1ThenR2();
        vault.setAssets(5e18); // yield the dispatcher really holds in a tracked vault
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 0, 0, address(0), 500_000);

        (uint256 reported, ) = _queuedTailReported();
        assertEq(reported, 5e18, "only the real remote residual is reported");

        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse(2);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 0, "settled fully debited");
        assertEq(executor.attestationAnchorPrincipal(REMOTE_CHAIN), 5e18, "honest residual anchors");

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL);
        uint256 pid = _propose(5e18);
        vm.prank(APPROVER);
        executor.approveBalance(pid);
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 5e18, "residual attested");
    }

    function testObservationShouldStillCountQueuedReturns() public {
        _bridge(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 0, 0, address(0), 500_000);

        assertEq(dispatcher.trackedIdle(), 60e18, "idle debited");
        assertEq(dispatcher.queuedTokenAmount(), 40e18, "R1 queued");
        assertEq(dispatcher.accountedBalance(), 100e18, "view keeps the queued tokens (audit M-8)");
        CcipObservation memory observed = dispatcher.observation();
        assertEq(observed.accountedBalance, 100e18, "observation keeps the queued tokens (audit M-8)");
        assertEq(observed.queuedTokenAmount, 40e18, "queued amount is exposed");
    }

    function testTransferSettledEvidenceShouldExcludeQueuedReturns() public {
        _bridge(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 0, 0, address(0), 500_000); // R1, v2
        _bridge(10e18); // TRANSFER_SETTLED, v3, queued behind R1
        assertEq(dispatcher.trackedIdle(), 70e18, "idle 60 + 10");
        assertEq(dispatcher.queuedTokenAmount(), 40e18, "R1 still queued");

        router.setFailSend(address(dispatcher), false);
        vm.recordLogs();
        dispatcher.flushResponse(2);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = CcipExecutorCommandLib.RemoteBalanceUpdated.selector;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(executor) || logs[i].topics[0] != topic) continue;
            (, uint256 balance, uint64 version) = abi.decode(logs[i].data, (uint256, uint256, uint64));
            if (version == 2) assertEq(balance, 60e18, "R1 evidence: idle after the debit");
            if (version == 3) assertEq(balance, 70e18, "settle evidence: R1 not counted again");
            ++found;
        }
        assertEq(found, 2, "both responses emitted evidence");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 70e18, "settled follows the evidence");
    }
}
