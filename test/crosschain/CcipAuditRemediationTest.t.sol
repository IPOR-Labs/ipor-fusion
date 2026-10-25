// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {BusinessAction, CcipChainRescue, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockSharePuller} from "./mocks/MockSharePuller.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ContextManager, ExecuteData} from "../../contracts/managers/context/ContextManager.sol";

contract AuditToken is ERC20 {
    uint8 private immutable _DEC;

    constructor(uint8 dec_) ERC20("USD", "USD") {
        _DEC = dec_;
    }

    function decimals() public view override returns (uint8) {
        return _DEC;
    }

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @dev ERC-4626 whose `convertToAssets` returns a value that is not a multiple of the local->shared
///      decimal conversion rate — i.e. an ordinary yield-bearing vault.
contract DustyVault is MockRemoteVault {
    uint256 public extra;

    constructor(IERC20 asset_) MockRemoteVault(asset_, "dusty", "DST") {}

    function addYield(uint256 amount_) external {
        extra += amount_;
    }

    function totalAssets() public view override returns (uint256) {
        return super.totalAssets() + extra;
    }
}

/// @title CcipAuditRemediationTest
/// @notice Regression coverage for the CCIP findings of `CROSSCHAIN_SECURITY_AUDIT_2026-08-03.md`.
///         Every test here reproduces the exact scenario that used to brick the transport.
contract CcipAuditRemediationTest is Test {
    bytes32 internal constant TRACKED_VAULT_SWEPT = keccak256("TrackedVaultSwept(address,uint256,uint256)");
    bytes32 internal constant TRACKED_VAULT_SWEEP_RESIDUAL =
        keccak256("TrackedVaultSweepResidual(address,uint256,uint8,bytes4,bool)");

    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    MockCcipRouter internal router;
    AuditToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    function _deploy(uint8 localDecimals_, uint8 sharedDecimals_) private {
        router = new MockCcipRouter();
        token = new AuditToken(localDecimals_);
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            sharedDecimals_,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            sharedDecimals_,
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
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
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
        vm.prank(address(0xA33));
        executor.approveBalance(proposalId);
    }

    function _toLD(uint256 amountSD_) private view returns (uint256) {
        return amountSD_ * executor.DECIMAL_CONVERSION_RATE();
    }

    // =====================================================================
    // H-01 — cancelling a failed config update must not commit its epoch
    // =====================================================================

    function testCancelOfFailedUpdateVaultsDoesNotBrickCommandLane() public {
        _deploy(18, 18);
        uint64 initialEpoch = executor.commandConfigEpoch(REMOTE_CHAIN);
        assertEq(initialEpoch, dispatcher.commandConfigEpoch(), "bootstrap epochs match");
        address[] memory invalid = new address[](1);
        invalid[0] = address(0xDEAD); // non-ERC4626: target-side validation NACKs
        executor.updateVaults(REMOTE_CHAIN, invalid, true, false, 0, address(0), 2_000_000);
        bytes32 failedId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(failedId)), uint8(CommandStatus.FAILED));
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), initialEpoch);
        assertEq(dispatcher.commandConfigEpoch(), initialEpoch);

        executor.cancelCommand(REMOTE_CHAIN, failedId, 0, address(0), 2_000_000);
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), initialEpoch, "cancel must not commit unapplied epoch");
        assertEq(dispatcher.commandConfigEpoch(), initialEpoch);

        MockRemoteVault validVault = new MockRemoteVault(IERC20(address(token)), "valid", "VALID");
        address[] memory valid = new address[](1);
        valid[0] = address(validVault);
        executor.updateVaults(REMOTE_CHAIN, valid, true, false, 0, address(0), 2_000_000);
        assertEq(
            executor.commandConfigEpoch(REMOTE_CHAIN),
            initialEpoch + 1,
            "next valid update advances executor epoch"
        );
        assertEq(dispatcher.commandConfigEpoch(), initialEpoch + 1, "next valid update advances dispatcher epoch");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "lane remains usable");
    }

    function testUpdateVaultsRejectsInvalidShapeAtSource() public {
        _deploy(18, 18);
        address[] memory zeroVault = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.InvalidVaultAddress.selector, address(0)));
        executor.updateVaults(REMOTE_CHAIN, zeroVault, true, false, 0, address(0), 2_000_000);

        address[] memory duplicates = new address[](2);
        duplicates[0] = address(0xBEEF);
        duplicates[1] = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.DuplicateVault.selector, address(0xBEEF)));
        executor.updateVaults(REMOTE_CHAIN, duplicates, true, false, 0, address(0), 2_000_000);

        address[] memory oversized = new address[](33);
        for (uint256 i; i < oversized.length; ++i) {
            oversized[i] = address(uint160(i + 1));
        }
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainExecutor.TooManyVaults.selector, 33, 32));
        executor.updateVaults(REMOTE_CHAIN, oversized, true, false, 0, address(0), 2_000_000);
    }

    function testObservationReturnsAtomicAccountingSnapshot() public {
        _deploy(18, 18);
        token.mint(address(executor), 25e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 25e18, 0, address(0), 2_000_000);

        CcipObservation memory observed = dispatcher.observation();
        assertEq(observed.accountedBalance, dispatcher.accountedBalance());
        assertEq(observed.trackedIdle, dispatcher.trackedIdle());
        assertEq(observed.queuedTokenAmount, dispatcher.queuedTokenAmount());
        assertEq(observed.stateVersion, dispatcher.stateVersion());
        assertEq(observed.commandConfigEpoch, dispatcher.commandConfigEpoch());
        assertEq(observed.trackedPositionSetHash, dispatcher.trackedPositionSetHash());
    }

    // =====================================================================
    // C-1 — a twice-failing command must not brick the ordered return lane
    // =====================================================================

    function testRepeatedCommandFailureKeepsReturnLaneAlive() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        // A deposit into a vault that is not on the allowlist fails on the dispatcher, every time.
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "v", "V");
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 1e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        bytes32 commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "first NACK applied");

        // The retry re-arms the command to PENDING (`markRetrying`), fails again and emits a SECOND NACK for the
        // same id. It is applied through the ordinary PENDING -> FAILED path instead of reverting and parking at
        // the queue head forever.
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 2_000_000);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "second NACK absorbed");
        assertEq(dispatcher.responseQueueHead(), 0, "response queue fully drained");

        // A third one, for good measure — the operator may retry as often as they like.
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 2_000_000);
        assertEq(dispatcher.responseQueueHead(), 0, "queue still drained");

        // Cancel frees the slot, and the recall lane still works end to end.
        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 2_000_000);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "cancel resolved");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "command slot freed");

        uint256 before = token.balanceOf(address(this));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 40e18, 40e18, 0, address(0), 2_000_000);
        executor.claimAsset(type(uint256).max);
        assertEq(token.balanceOf(address(this)) - before, 40e18, "recalled funds reached the vault");
    }

    // =====================================================================
    // C-2 — vault dust must not brick the dispatcher
    // =====================================================================

    function testVaultDustDoesNotBrickDispatcher() public {
        _deploy(18, 6); // rate = 1e12: the real "USDC shared decimals, 18-decimal local asset" shape
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedIdle(), 100e6, "credited in shared decimals");
        _attest(100e6);

        DustyVault vault = new DustyVault(IERC20(address(token)));
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);

        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        assertGt(IERC20(address(vault)).balanceOf(address(dispatcher)), 0, "position opened");

        // Ordinary yield accrual leaves sub-shared-decimal dust in convertToAssets().
        vault.addYield(1_234_567);
        assertTrue(vault.convertToAssets(IERC20(address(vault)).balanceOf(address(dispatcher))) % 1e12 != 0);

        // The dispatcher keeps reporting, keeps accepting value, and keeps honouring recalls.
        uint256 reported = dispatcher.accountedBalance();
        assertGt(reported, 0, "balance still reportable");

        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedIdle(), 60e6, "further bridging still settles");

        uint256 before = token.balanceOf(address(this));
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 10e18, 0, 0, address(0), 2_000_000);
        executor.claimAsset(type(uint256).max);
        assertEq(token.balanceOf(address(this)) - before, 10e18, "recall still works");
    }

    /// @dev The dust itself must never be minted into the ledger — flooring keeps it as untracked surplus.
    function testInboundDustIsFlooredNotCredited() public {
        _deploy(18, 6);
        token.mint(address(dispatcher), 1); // stray wei already sitting on the dispatcher
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedIdle(), 100e6, "dust excluded from the tracked ledger");
        assertEq(token.balanceOf(address(dispatcher)), 100e18 + 1, "dust remains as untracked surplus");
    }

    // =====================================================================
    // M-8 — queued return tokens stay inside the reported remote balance
    // =====================================================================

    function testQueuedReturnRemainsInReportedBalance() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);
        assertEq(dispatcher.accountedBalance(), 100e18);

        // Break delivery so the return leg is queued but never dispatched.
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);

        assertEq(dispatcher.trackedIdle(), 40e18, "idle debited at queue time");
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "value parked in the queue");
        assertEq(dispatcher.accountedBalance(), 100e18, "reported remote balance unchanged");

        // Once transport recovers the value leaves and the reported balance drops exactly once.
        router.setFailSend(address(dispatcher), false);
        dispatcher.flushResponse();
        assertEq(dispatcher.queuedTokenAmount(), 0);
        assertEq(dispatcher.accountedBalance(), 40e18, "reported balance drops on delivery");
        assertEq(executor.idleLedger(), 60e18, "credited home exactly once");
    }

    // =====================================================================
    // IL-8064 — skipping a queued return response must not drop its tokens from NAV
    // =====================================================================

    /// @dev `MockCcipRouter` delivers every message synchronously (`ccipSend`,
    ///      test/crosschain/mocks/MockCcipRouter.sol:43-75), so a response can only get physically stuck at
    ///      the queue head by forcing the send to fail at queue time — the same device
    ///      `CcipStateVersionGapTest._burnOneRemoteStateVersion` uses to reach this state.
    function testSkippedReturnResponseRecreditsTrackedIdleAndKeepsAccountedBalance() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        // Break delivery so the return leg is queued but never dispatched, then drop it.
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        uint64 stuck = dispatcher.responseQueueHead();

        vm.prank(address(0xA11));
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeSkipStuckResponse(skipId, stuck);

        assertEq(dispatcher.queuedTokenAmount(), 0, "queue bucket released");
        assertEq(dispatcher.trackedIdle(), 100e18, "value re-credited to idle instead of dropped (IL-8064)");
        assertEq(dispatcher.accountedBalance(), 100e18, "reported remote balance unchanged by the skip");
        assertEq(token.balanceOf(address(dispatcher)), 100e18, "tokens never left the dispatcher");
        assertEq(dispatcher.responseQueueHead(), 0, "queue head advanced past the dropped response");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "executor still counts the value as settled");
    }

    /// @dev Without the re-credit, the sum `trackedIdle + queuedTokenAmount` the rescue floor reads
    ///      (`_afterRescueExecuted`, CcipCrosschainDispatcher.sol:676-680) drops by the skipped amount, so an
    ///      ordinary `transfer` rescue of that same amount passes the post-call check and drains tracked
    ///      value as if it were untracked surplus. With the fix the floor is unchanged by the skip, so the
    ///      identical rescue call must revert.
    function testSkippedReturnResponseKeepsRescueFloorIntact() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        uint64 stuck = dispatcher.responseQueueHead();

        vm.prank(address(0xA11));
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeSkipStuckResponse(skipId, stuck);

        bytes memory drainCall = abi.encodeCall(IERC20.transfer, (address(0xA11), 60e18));
        vm.prank(address(0xA11));
        uint256 rescueId = dispatcher.scheduleRescue(address(token), 0, drainCall);
        vm.warp(block.timestamp + 3 days);

        // `_afterRescueExecuted` compares the post-transfer balance (100e18 - 60e18 = 40e18) against the
        // still-honest floor `_toLD(trackedIdle + queuedTokenAmount)` = 100e18: the drain would take tracked
        // value, not surplus, so it must revert instead of succeeding as it did pre-fix. `vm.expectRevert`
        // applies to the next external call, so nothing reads state between it and `executeRescue`.
        vm.prank(address(0xA11));
        vm.expectRevert(
            abi.encodeWithSelector(CcipCrosschainDispatcher.InsufficientTrackedIdle.selector, 40e18, 100e18)
        );
        dispatcher.executeRescue(rescueId, drainCall);

        assertEq(token.balanceOf(address(dispatcher)), 100e18, "drain did not move any tokens");
        assertEq(token.balanceOf(address(0xA11)), 0, "rescue admin received nothing");
    }

    /// @dev Round trip proving the recall — not a rescue — is how the stranded value comes home, and that
    ///      no bucket double-counts it. Branch map, traced against the code rather than assumed:
    ///      after the skip, `chainBlocked[REMOTE_CHAIN]` is still `false` and `activeReturn[REMOTE_CHAIN]`
    ///      is still set (the skip never touches either). `cancelPendingReturn` only flips the pending
    ///      record to `CANCELLED` and clears `activeReturn` — no accounting effect — so the second
    ///      `requestAssetsFromDispatcher` is not blocked by `ActiveReturnExists` and is not gated by
    ///      `chainBlocked` (`_requireReady` only checks `hasDispatcher`,
    ///      `CcipCrosschainExecutor.sol:863-865`). The dispatcher bumps `stateVersion` a third time for the
    ///      new `RETURN_TRANSFER` (the skipped response consumed the second bump without ever reaching the
    ///      executor), so that receipt arrives ahead of the frontier. Since IL-8496 it fails on the gap
    ///      (`StateVersionGap`) with nothing applied and waits; the timelocked `ADVANCE_FRONTIER` past the
    ///      lost version lets it deliver, and the round trip completes. The repair leaves its own block, armed
    ///      with `frontierRepairPending`, so the following approval lifts it. Without the re-credit, the second recall would
    ///      instead clamp to the shrunken `trackedIdle` (40e18) and reject `BELOW_MINIMUM` against the
    ///      60e18 floor (`CcipCrosschainDispatcher._returnAssets`), so the round trip could never complete.
    function testSkippedReturnCanBeRecalledAgainAfterExecutorCancel() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        uint64 stuck = dispatcher.responseQueueHead();

        vm.prank(address(0xA11));
        uint256 skipId = dispatcher.scheduleSkipStuckResponse(stuck);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeSkipStuckResponse(skipId, stuck);

        executor.cancelPendingReturn(REMOTE_CHAIN);
        router.setFailSend(address(dispatcher), false);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);

        // The skipped response consumed a state version, so the new RETURN_TRANSFER arrives ahead of the
        // frontier and fails on the gap (IL-8496): nothing is credited and its tokens do not move. Here it
        // stays at the head of the dispatcher's queue (the mock bubbles the receiver revert into the send); on
        // CCIP it is a FAILURE on the OffRamp, token release included.
        assertEq(executor.idleLedger(), 0, "nothing credited on the gap");
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "the return waits in the dispatcher's queue");
        assertEq(dispatcher.accountedBalance(), 100e18, "queued return still counted remotely");
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "the gap itself does not block the chain");

        // Timelocked repair past the lost version only, then the held return is delivered.
        uint256 lostVersion = uint256(dispatcher.stateVersion()) - 1;
        vm.prank(address(0xA11));
        uint256 repairId = executor.scheduleChainRescue(CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, lostVersion);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeChainRescue(repairId, CcipChainRescue.ADVANCE_FRONTIER, REMOTE_CHAIN, lostVersion);
        dispatcher.flushResponse();

        assertEq(executor.idleLedger(), 60e18, "the recalled value came home through the audited path");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "settled debited exactly once");
        assertEq(dispatcher.trackedIdle(), 40e18, "dispatcher idle debited for the delivered recall");
        assertEq(dispatcher.accountedBalance(), 40e18, "reported remote balance reflects the round trip");
        assertEq(token.balanceOf(address(dispatcher)), 40e18, "tokens left the dispatcher exactly once");
        assertEq(token.balanceOf(address(executor)), 60e18, "tokens arrived home exactly once");
        // The frontier repair leaves its own block until a fresh approved attestation (R-06).
        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), dispatcher.stateVersion(), "frontier caught up");
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "repair block, lifted by the next approved attestation");
        // IL-8590: the repair also cleared the cancelled recall's clock, so a fresh approval reopens NAV.
        assertEq(executor.cancelledRecallCount(REMOTE_CHAIN), 0, "cancelled clock cleared by the repair");
        _attest(dispatcher.accountedBalance());
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "approval lifts the repair block");
        assertEq(executor.getBalance(), 100e18, "NAV conserved after the repair");
    }

    // =====================================================================
    // M-6 — replacement allowlist semantics match Stargate
    // =====================================================================

    function testUpdateVaultsCanReplaceTheWholeAllowlist() public {
        _deploy(18, 18);
        MockRemoteVault a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        MockRemoteVault b = new MockRemoteVault(IERC20(address(token)), "b", "B");

        address[] memory both = new address[](2);
        both[0] = address(a);
        both[1] = address(b);
        executor.updateVaults(REMOTE_CHAIN, both, true, false, 0, address(0), 2_000_000);
        assertTrue(dispatcher.isAllowedVault(address(a)));
        assertTrue(dispatcher.isAllowedVault(address(b)));

        address[] memory onlyB = new address[](1);
        onlyB[0] = address(b);
        executor.updateVaults(REMOTE_CHAIN, onlyB, true, true, 0, address(0), 2_000_000);
        assertFalse(dispatcher.isAllowedVault(address(a)), "replaced out of the allowlist");
        assertTrue(dispatcher.isAllowedVault(address(b)), "kept");
        assertEq(dispatcher.trackedVaultsLength(), 1, "position-free vault dropped from tracking");
    }

    /// @dev IL-8784: a replaced-out vault that still holds a position is swept into idle and untracked, so NAV never
    ///      drops its value (the position becomes idle). Was: "stays tracked" (IL-8630).
    function testReplacementSweepsLivePositionsIntoIdleKeepingNav() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        MockRemoteVault a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        address[] memory only = new address[](1);
        only[0] = address(a);
        executor.updateVaults(REMOTE_CHAIN, only, true, false, 0, address(0), 2_000_000);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(a), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );

        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);
        assertFalse(dispatcher.isAllowedVault(address(a)), "no longer accepts new deposits");
        assertFalse(dispatcher.isTrackedVault(address(a)), "live position swept and untracked");
        assertEq(a.balanceOf(address(dispatcher)), 0, "position redeemed");
        assertEq(dispatcher.accountedBalance(), 100e18, "value never left NAV");
    }

    // IL-8467 — allowlist changes are fully observable from events

    function _twoVaults() private returns (MockRemoteVault a, MockRemoteVault b) {
        a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        b = new MockRemoteVault(IERC20(address(token)), "b", "B");
    }

    function _allowBoth(MockRemoteVault a, MockRemoteVault b) private {
        address[] memory both = new address[](2);
        both[0] = address(a);
        both[1] = address(b);
        executor.updateVaults(REMOTE_CHAIN, both, true, false, 0, address(0), 2_000_000);
    }

    function testShouldEmitVaultAllowedFalseForEveryVaultClearedByEmptyReplace() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();
        _allowBoth(a, b);

        // bootstrap took epoch 1, the allow command epoch 2, so this replacement lands on epoch 3
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(a), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(b), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultsConfigured(3, true, true, 0);
        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);

        assertFalse(dispatcher.isAllowedVault(address(a)));
        assertFalse(dispatcher.isAllowedVault(address(b)));
        assertEq(dispatcher.commandConfigEpoch(), 3);
    }

    function testShouldEmitClearThenAllowWhenReplacingWithDisjointVault() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();
        MockRemoteVault c = new MockRemoteVault(IERC20(address(token)), "c", "C");
        _allowBoth(a, b);

        address[] memory onlyC = new address[](1);
        onlyC[0] = address(c);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(a), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(b), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(c), true);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultsConfigured(3, true, true, 1);
        executor.updateVaults(REMOTE_CHAIN, onlyC, true, true, 0, address(0), 2_000_000);

        assertFalse(dispatcher.isAllowedVault(address(a)));
        assertFalse(dispatcher.isAllowedVault(address(b)));
        assertTrue(dispatcher.isAllowedVault(address(c)));
    }

    function testShouldEmitClearThenAllowWhenReplacingWithOverlappingVault() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();
        _allowBoth(a, b);

        address[] memory onlyA = new address[](1);
        onlyA[0] = address(a);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(a), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(b), false);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(a), true);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultsConfigured(3, true, true, 1);
        executor.updateVaults(REMOTE_CHAIN, onlyA, true, true, 0, address(0), 2_000_000);

        assertTrue(dispatcher.isAllowedVault(address(a)));
        assertFalse(dispatcher.isAllowedVault(address(b)));
    }

    /// @dev IL-8784: after the first replacement the vault is swept and untracked. A vault already disallowed is not
    ///      a change: a later replacement must not emit `VaultAllowed(vault, false)` for it again.
    function testShouldNotEmitVaultAllowedForTrackedButAlreadyDisallowedVault() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        MockRemoteVault a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        address[] memory only = new address[](1);
        only[0] = address(a);
        executor.updateVaults(REMOTE_CHAIN, only, true, false, 0, address(0), 2_000_000);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(a), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );

        // first replacement is a real change: allowed -> disallowed, swept and untracked (IL-8784)
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultAllowed(address(a), false);
        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);
        assertFalse(dispatcher.isTrackedVault(address(a)));

        // second replacement: no flag change, so no VaultAllowed for `a`
        vm.recordLogs();
        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 allowedEvents;
        uint256 configuredEvents;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher)) continue;
            if (logs[i].topics[0] == CcipCrosschainDispatcher.VaultAllowed.selector) ++allowedEvents;
            if (logs[i].topics[0] == CcipCrosschainDispatcher.VaultsConfigured.selector) ++configuredEvents;
        }
        assertEq(allowedEvents, 0, "no VaultAllowed for an unchanged flag");
        assertEq(configuredEvents, 1, "the config change itself is still announced");
        assertFalse(dispatcher.isTrackedVault(address(a)));
    }

    // IL-8476 — tracked-position set membership changes are observable from events

    function _countDispatcherLogs(Vm.Log[] memory logs, bytes32 topic0) private view returns (uint256 n) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == topic0) ++n;
        }
    }

    function testShouldEmitVaultTrackedWhenAllowingNewVault() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();

        address[] memory one = new address[](1);
        one[0] = address(a);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultTracked(address(a));
        executor.updateVaults(REMOTE_CHAIN, one, true, false, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedVaults(0), address(a));

        // allowing an already-tracked vault again is not a membership change
        vm.recordLogs();
        executor.updateVaults(REMOTE_CHAIN, one, true, false, 0, address(0), 2_000_000);
        assertEq(_countDispatcherLogs(vm.getRecordedLogs(), CcipCrosschainDispatcher.VaultTracked.selector), 0);

        one[0] = address(b);
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultTracked(address(b));
        executor.updateVaults(REMOTE_CHAIN, one, true, false, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedVaultsLength(), 2);
    }

    function testShouldEmitVaultUntrackedForPositionFreeVaultsOnEmptyReplace() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();
        _allowBoth(a, b);

        // reverse iteration untracks `b` first, then `a`
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultUntracked(address(b));
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultUntracked(address(a));
        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedVaultsLength(), 0);
    }

    function testShouldReorderTrackedSetBySwapAndPopWhenVaultIsUntracked() public {
        _deploy(18, 18);
        (MockRemoteVault a, MockRemoteVault b) = _twoVaults();
        MockRemoteVault c = new MockRemoteVault(IERC20(address(token)), "c", "C");
        address[] memory all = new address[](3);
        all[0] = address(a);
        all[1] = address(b);
        all[2] = address(c);
        executor.updateVaults(REMOTE_CHAIN, all, true, false, 0, address(0), 2_000_000);
        assertEq(dispatcher.trackedVaults(0), address(a));
        assertEq(dispatcher.trackedVaults(2), address(c));
        bytes32 hashBefore = dispatcher.trackedPositionSetHash();

        address[] memory bc = new address[](2);
        bc[0] = address(b);
        bc[1] = address(c);
        vm.recordLogs();
        vm.expectEmit(address(dispatcher));
        emit CcipCrosschainDispatcher.VaultUntracked(address(a));
        executor.updateVaults(REMOTE_CHAIN, bc, true, true, 0, address(0), 2_000_000);
        assertEq(_countDispatcherLogs(vm.getRecordedLogs(), CcipCrosschainDispatcher.VaultTracked.selector), 0);

        // `c` (the last element) was swapped into `a`'s slot
        assertEq(dispatcher.trackedVaultsLength(), 2);
        assertEq(dispatcher.trackedVaults(0), address(c));
        assertEq(dispatcher.trackedVaults(1), address(b));
        assertTrue(dispatcher.trackedPositionSetHash() != hashBefore, "hash follows the reorder");
    }

    /// @dev IL-8784 (reverses IL-8630): a replaced-out vault holding a live position is swept into idle and untracked
    ///      in the same command. Dropping the sweep (leaving the position tracked) fails the shares / idle asserts.
    function testShouldSweepAndUntrackReplacedOutVaultHoldingLivePosition() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        MockRemoteVault a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        address[] memory only = new address[](1);
        only[0] = address(a);
        executor.updateVaults(REMOTE_CHAIN, only, true, false, 0, address(0), 2_000_000);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(a), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        assertEq(a.balanceOf(address(dispatcher)), 50e18, "live position before the replace");
        assertEq(dispatcher.trackedIdle(), 50e18, "idle after the deposit");

        vm.recordLogs();
        executor.updateVaults(REMOTE_CHAIN, new address[](0), true, true, 0, address(0), 2_000_000);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_countDispatcherLogs(logs, CcipCrosschainDispatcher.VaultUntracked.selector), 1, "untracked");
        assertEq(_countDispatcherLogs(logs, TRACKED_VAULT_SWEPT), 1, "swept event");
        assertEq(_countDispatcherLogs(logs, TRACKED_VAULT_SWEEP_RESIDUAL), 0, "no residual on a clean redeem");
        assertFalse(dispatcher.isTrackedVault(address(a)), "untracked");
        assertEq(a.balanceOf(address(dispatcher)), 0, "position redeemed");
        assertEq(dispatcher.trackedIdle(), 100e18, "redeemed assets credited to idle");
        assertEq(token.balanceOf(address(dispatcher)), 100e18, "assets back on the dispatcher");
    }

    function testShouldEmitVaultsConfiguredOnFactoryBootstrap() public {
        vm.recordLogs();
        _deploy(18, 18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(dispatcher)) continue;
            if (logs[i].topics[0] != CcipCrosschainDispatcher.VaultsConfigured.selector) continue;
            (uint64 epoch, bool replace, bool allowed, uint256 count) = abi.decode(
                logs[i].data,
                (uint64, bool, bool, uint256)
            );
            assertEq(epoch, 1, "bootstrap epoch");
            assertFalse(replace);
            assertTrue(allowed);
            assertEq(count, 0);
            ++found;
        }
        assertEq(found, 1);
    }

    // =====================================================================
    // M-7 — the factory allowlist bootstrap is one-shot
    // =====================================================================

    function testFactoryVaultBootstrapIsOneShot() public {
        _deploy(18, 18);
        vm.prank(factory);
        vm.expectRevert(CcipCrosschainDispatcher.VaultsAlreadyInitialized.selector);
        dispatcher.configureVaults(new address[](0), true);
    }

    // =====================================================================
    // L-2 / L-4 — business-action edge cases match the Stargate dispatcher
    // =====================================================================

    function testRedeemClampsToHeldSharesInsteadOfFailing() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);

        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "v", "V");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );

        // Ask for more shares than are held: clamped, not NACKed.
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(address(vault), 999e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        bytes32 commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(commandId, bytes32(0), "command resolved, slot free");
        assertEq(dispatcher.trackedIdle(), 100e18, "whole position unwound");
    }

    function testZeroAmountDepositIsRejected() public {
        _deploy(18, 18);
        MockRemoteVault vault = new MockRemoteVault(IERC20(address(token)), "v", "V");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);

        // trackedIdle is zero, so the deposit clamps to zero — it must NACK, not silently succeed.
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 10e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        bytes32 commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "no-op deposit NACKed");
        // The preceding updateVaults consumed sequence 0; a FAILED command must not advance past 1.
        assertEq(dispatcher.nextCommandSequence(), 1, "sequence not consumed by the failed command");
    }

    /// @notice Sibling of the Stargate `RescueProtectedTokenCall` regression (audit R-series): both CCIP
    ///         halves enforce their tracked-idle invariant with a post-call balance snapshot, which an
    ///         `approve` leaves untouched. The schedule-time guard must reject it on both, otherwise the
    ///         rescue admin walks away with an allowance over tracked value and pulls it later outside
    ///         the timelock and the guardian's veto window.
    function testShouldBlockCcipRescueGrantingAllowanceOverTrackedAsset() public {
        _deploy(18, 18);
        address rescueAdmin = address(0xA11);
        bytes memory cd = abi.encodeCall(IERC20.approve, (rescueAdmin, type(uint256).max));

        vm.prank(rescueAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector,
                address(token),
                IERC20.approve.selector
            )
        );
        executor.scheduleRescue(address(token), 0, cd);

        vm.prank(rescueAdmin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector,
                address(token),
                IERC20.approve.selector
            )
        );
        dispatcher.scheduleRescue(address(token), 0, cd);

        assertEq(token.allowance(address(executor), rescueAdmin), 0, "executor granted no allowance");
        assertEq(token.allowance(address(dispatcher), rescueAdmin), 0, "dispatcher granted no allowance");
    }

    /// @notice IL-8261 sibling: the factory-target guard lives in the shared `RescueLogicLib`, so both CCIP
    ///         halves reject a rescue call to their `FACTORY()` too.
    function testShouldBlockCcipRescueCallingFactory() public {
        _deploy(18, 18);
        address rescueAdmin = address(0xA11);

        vm.prank(rescueAdmin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueFactoryCall.selector, factory));
        executor.scheduleRescue(factory, 0, "");

        vm.prank(rescueAdmin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueFactoryCall.selector, factory));
        dispatcher.scheduleRescue(factory, 0, "");
    }

    /// @notice IL-8770: the shared `RescueLogicLib` rejects a `runWithContext` rescue on both CCIP halves.
    function testShouldBlockCcipRescueRunWithContext() public {
        _deploy(18, 18);
        address rescueAdmin = address(0xA11);
        address contextManager = address(0xC0C0);
        address[] memory targets = new address[](1);
        targets[0] = address(0xBEEF);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeWithSignature("approve(address,uint256)", rescueAdmin, type(uint256).max);
        bytes memory cd = abi.encodeCall(
            ContextManager.runWithContext,
            (ExecuteData({targets: targets, datas: datas}))
        );

        vm.prank(rescueAdmin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, contextManager));
        dispatcher.scheduleRescue(contextManager, 0, cd);
        assertEq(dispatcher.rescueCount(), 0, "dispatcher: nothing queued");

        vm.prank(rescueAdmin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, contextManager));
        executor.scheduleRescue(contextManager, 0, cd);
        assertEq(executor.rescueCount(), 0, "executor: nothing queued");
    }

    // =====================================================================
    // IL-8251 — tracked idle has a timelocked admin exit when the lane is dead
    // =====================================================================

    /// @dev Both directions of the lane refuse to send, so neither a recall nor a forged executor message
    ///      can reach the dispatcher. The admin recall moves the tracked idle to the rescue admin anyway,
    ///      and the executor's `FORCE_SET_SETTLED` reconciles NAV to the value that stayed remote.
    function testAdminRecallReturnsTrackedIdleWhenLaneIsDead() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);
        router.setFailSend(address(executor), true);
        router.setFailSend(address(dispatcher), true);
        uint64 versionBefore = dispatcher.stateVersion();

        vm.prank(address(0xA11));
        uint256 recallId = dispatcher.scheduleAdminRecall(60e18);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeAdminRecall(recallId, 60e18);

        assertEq(token.balanceOf(address(0xA11)), 60e18, "rescue admin received the recalled idle");
        assertEq(token.balanceOf(address(dispatcher)), 40e18, "remainder stays on the dispatcher");
        assertEq(dispatcher.trackedIdle(), 40e18, "tracked idle debited");
        assertEq(dispatcher.accountedBalance(), 40e18, "reported remote balance follows the debit");
        assertEq(dispatcher.stateVersion(), versionBefore, "recall leaves the state version unchanged");
        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 100e18, "executor unchanged until force-set");

        // The balance is read at the dispatcher's current state version (IL-8294).
        uint256 arg = (uint256(dispatcher.stateVersion()) << 192) | (block.timestamp << 128) | 40e18;
        vm.prank(address(0xA11));
        uint256 settleId = executor.scheduleChainRescue(CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        executor.executeChainRescue(settleId, CcipChainRescue.FORCE_SET_SETTLED, REMOTE_CHAIN, arg);

        assertEq(executor.settledRemoteBalance(REMOTE_CHAIN), 40e18, "executor NAV reconciled to the remainder");
    }

    /// @dev The recall sends no response, so it must not consume a state version either: otherwise the
    ///      first response after the lane revives lands two versions ahead of the executor's frontier,
    ///      which raises the gap block and freezes NAV until a timelocked `ADVANCE_FRONTIER` repair.
    function testAdminRecallDoesNotGapExecutorFrontierWhenLaneRevives() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);
        router.setFailSend(address(executor), true);
        router.setFailSend(address(dispatcher), true);

        vm.prank(address(0xA11));
        uint256 recallId = dispatcher.scheduleAdminRecall(60e18);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeAdminRecall(recallId, 60e18);

        router.setFailSend(address(executor), false);
        router.setFailSend(address(dispatcher), false);
        uint64 frontier = executor.lastRemoteStateVersion(REMOTE_CHAIN);
        // The first VALUE-MOVING response after revival (an outbound transfer settling; a balance report
        // carries no version since IL-8257).
        token.mint(address(executor), 10e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 10e18, 0, address(0), 2_000_000);

        assertEq(
            executor.lastRemoteStateVersion(REMOTE_CHAIN),
            frontier + 1,
            "first settle after revival is contiguous"
        );
        assertFalse(executor.chainBlocked(REMOTE_CHAIN), "no frontier gap block");
    }

    /// @dev A recall scheduled for more than is idle executes the idle only; value debited into an
    ///      undispatched return response is not idle and stays under the rescue floor.
    function testAdminRecallClampsToTrackedIdleAndSparesQueuedValue() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);
        router.setFailSend(address(dispatcher), true);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 60e18, 60e18, 0, address(0), 2_000_000);
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "return stuck in the queue");

        vm.prank(address(0xA11));
        uint256 recallId = dispatcher.scheduleAdminRecall(100e18);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeAdminRecall(recallId, 100e18);

        assertEq(token.balanceOf(address(0xA11)), 40e18, "only the tracked idle was recalled");
        assertEq(dispatcher.trackedIdle(), 0, "tracked idle drained");
        assertEq(dispatcher.queuedTokenAmount(), 60e18, "queued response untouched");
        assertEq(token.balanceOf(address(dispatcher)), 60e18, "queued value still backed");
    }

    function testAdminRecallIsAdminOnlyTimelockedCommittedAndVetoable() public {
        _deploy(18, 18);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        dispatcher.scheduleAdminRecall(1e18);

        vm.prank(address(0xA11));
        uint256 recallId = dispatcher.scheduleAdminRecall(10e18);
        (, , uint64 executableAt, , , , ) = dispatcher.rescues(recallId);

        vm.prank(address(0xA11));
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector,
                recallId,
                block.timestamp,
                executableAt
            )
        );
        dispatcher.executeAdminRecall(recallId, 10e18);

        vm.warp(executableAt);
        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 11e18);

        vm.prank(address(0xB22));
        dispatcher.vetoAllPendingRescues();
        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 10e18);

        assertEq(dispatcher.trackedIdle(), 100e18, "no recall took effect");
        assertEq(token.balanceOf(address(0xA11)), 0, "rescue admin received nothing");
    }

    /// @dev With nothing idle the recall clamps to zero: it moves no tokens and only consumes the record.
    function testAdminRecallWithoutTrackedIdleMovesNothing() public {
        _deploy(18, 18);
        token.mint(address(dispatcher), 5e18); // untracked surplus is not part of the recall
        vm.prank(address(0xA11));
        uint256 recallId = dispatcher.scheduleAdminRecall(10e18);
        vm.warp(block.timestamp + 3 days);

        vm.prank(address(0xA11));
        dispatcher.executeAdminRecall(recallId, 10e18);
        assertEq(token.balanceOf(address(0xA11)), 0, "nothing recalled");
        assertEq(token.balanceOf(address(dispatcher)), 5e18, "surplus untouched");

        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueAlreadyConsumed.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 10e18);
    }

    // =====================================================================
    // IL-8555 / IL-8556 — rescue fences: transport ban and tracked-vault shares
    // =====================================================================

    function testShouldBlockCcipRescueCallingRouter() public {
        _deploy(18, 18);
        bytes memory cd = abi.encodeWithSignature("ccipSend(uint64,bytes)", EXECUTOR_SELECTOR, bytes("x"));
        bytes4 sel = bytes4(cd);

        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTransportCall.selector, address(router), sel));
        executor.scheduleRescue(address(router), 0, cd);

        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTransportCall.selector, address(router), sel));
        dispatcher.scheduleRescue(address(router), 0, cd);
    }

    function _trackedVaultWithShares() private returns (MockRemoteVault a) {
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(100e18);
        a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        address[] memory only = new address[](1);
        only[0] = address(a);
        executor.updateVaults(REMOTE_CHAIN, only, true, false, 0, address(0), 2_000_000);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(a), 50e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        assertTrue(dispatcher.isTrackedVault(address(a)));
        assertGt(a.balanceOf(address(dispatcher)), 0, "dispatcher holds shares");
    }

    function testShouldBlockCcipRescueOnTrackedVault() public {
        _deploy(18, 18);
        MockRemoteVault a = _trackedVaultWithShares();
        bytes memory approveCd = abi.encodeCall(IERC20.approve, (address(0xA11), type(uint256).max));
        bytes memory redeemCd = abi.encodeWithSignature(
            "redeem(uint256,address,address)",
            1e18,
            address(0xA11),
            address(dispatcher)
        );

        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(a)));
        dispatcher.scheduleRescue(address(a), 0, approveCd);
        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(a)));
        dispatcher.scheduleRescue(address(a), 0, redeemCd);

        // The executor has no tracked set: the fence is dispatcher-scoped.
        vm.prank(address(0xA11));
        executor.scheduleRescue(address(a), 0, approveCd);
    }

    /// @notice On CCIP an allowlisted vault is tracked at once, so allowing it during the timelock turns an
    ///         accepted schedule into an execute-time rejection.
    function testShouldBlockCcipRescueOnVaultTrackedAfterSchedule() public {
        _deploy(18, 18);
        MockRemoteVault a = new MockRemoteVault(IERC20(address(token)), "a", "A");
        bytes memory cd = abi.encodeCall(IERC20.approve, (address(0xA11), type(uint256).max));
        vm.prank(address(0xA11));
        uint256 id = dispatcher.scheduleRescue(address(a), 0, cd);

        address[] memory only = new address[](1);
        only[0] = address(a);
        executor.updateVaults(REMOTE_CHAIN, only, true, false, 0, address(0), 2_000_000);
        assertTrue(dispatcher.isTrackedVault(address(a)), "allowing tracks it");

        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(a)));
        dispatcher.executeRescue(id, cd);
    }

    function testShouldBlockCcipRescueThatReducesTrackedShares() public {
        _deploy(18, 18);
        MockRemoteVault a = _trackedVaultWithShares();
        uint256 held = a.balanceOf(address(dispatcher));
        MockSharePuller puller = new MockSharePuller();
        vm.prank(address(dispatcher));
        a.approve(address(puller), type(uint256).max);
        bytes memory cd = abi.encodeCall(
            MockSharePuller.pull,
            (IERC20(address(a)), address(dispatcher), address(0xA11), 1e18)
        );

        vm.prank(address(0xA11));
        uint256 id = dispatcher.scheduleRescue(address(puller), 0, cd);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueTrackedSharesReduced.selector, address(a), held, held - 1e18)
        );
        dispatcher.executeRescue(id, cd);
    }

    function testShouldAllowCcipRescueLeavingTrackedSharesUnchanged() public {
        _deploy(18, 18);
        MockRemoteVault a = _trackedVaultWithShares();
        uint256 held = a.balanceOf(address(dispatcher));
        AuditToken other = new AuditToken(18);
        other.mint(address(dispatcher), 5e18);
        bytes memory cd = abi.encodeCall(IERC20.transfer, (address(0xA11), 5e18));
        vm.prank(address(0xA11));
        uint256 id = dispatcher.scheduleRescue(address(other), 0, cd);
        vm.warp(block.timestamp + 3 days);
        vm.prank(address(0xA11));
        dispatcher.executeRescue(id, cd);
        assertEq(other.balanceOf(address(0xA11)), 5e18);
        assertEq(a.balanceOf(address(dispatcher)), held);
    }
}
