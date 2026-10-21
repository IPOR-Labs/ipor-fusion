// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {
    MsgType,
    BusinessAction,
    CommandStatus,
    ReturnRejectReason
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    CommandAck,
    UpdateVaults,
    OutboundTransfer,
    ReturnAssetsRequest,
    ReturnRejected,
    RetryCommand,
    CancelCommand
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {ContextManager, ExecuteData} from "../../contracts/managers/context/ContextManager.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockSharePuller} from "./mocks/MockSharePuller.sol";
import {
    MockRemoteVault,
    MockWithdrawManager,
    MockRemotePlasmaVault,
    MockPermissiveAuthority
} from "./mocks/MockRemoteVault.sol";
import {ReadResult} from "../../contracts/universal_reader/UniversalReader.sol";
import {MockLegacyRemotePlasmaVault} from "./mocks/MockLegacyRemotePlasmaVault.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title DispatcherTest
/// @notice Drives the remote-chain `StargateCrosschainDispatcher` handlers directly: DEPOSIT/REDEEM measured deltas +
///         slippage, REQUEST_SHARES post-fee request (against a mock WM and, for the IL-8118 regression tests,
///         the real `WithdrawManager`), REDEEM_FROM_REQUEST, UPDATE_VAULTS config epoch +
///         validation, inbound compose -> trackedIdle + TRANSFER_SETTLED, SequenceGap, the recall lane
///         (RETURN_ASSETS / RETRY / CANCEL), and the executor-chain binding (plan §4.4, spec §10).
/// @dev Dispatcher is deployed from its artifact (`deployCode`) under `--code-size-limit 60000`.
contract DispatcherTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161; // where the dispatcher lives
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    uint256 internal constant RESCUE_DELAY = 3 days;
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);
    bytes32 internal constant GUID = keccak256("guid");

    /// @dev Local re-declaration of the dispatcher event for `vm.expectEmit` topic matching. This event
    ///      declares no indexed params, so `vm.expectEmit(false, false, false, true, ...)` matches on the
    ///      data section.
    event ReturnAssetsRejected(bytes32 requestId, uint8 reason);

    /// @dev Local re-declaration of `SharesRequested` post-IL-8118 (second param renamed `requestSharesDelta`
    ///      -> `pendingShares`, now emitting the outstanding request read back from the manager, never a
    ///      delta). The topic is unchanged (`SharesRequested(address,uint256)` hashes on types, not names).
    event SharesRequested(address vault, uint256 pendingShares, uint256 feeShares);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockRemoteVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vault = new MockRemoteVault(IERC20(address(usdc)), "Vault", "VLT");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF),
            admin,
            guardian,
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    function testShouldBlockDispatcherRescueThatTakesTrackedIdle() public {
        _compose(keccak256("tracked"), 100e6);
        bytes memory callData = abi.encodeCall(IERC20.transfer, (admin, 1));

        vm.prank(admin);
        uint256 rescueId = dispatcher.scheduleRescue(address(usdc), 0, callData);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueLedgerInvariantViolation.selector,
                uint256(100e6 - 1),
                uint256(100e6)
            )
        );
        dispatcher.executeRescue(rescueId, callData);
    }

    /// @notice Mirror of `RescueModuleTest.testShouldBlockRescueGrantingAllowanceOverTrackedAsset` on the
    ///         remote half: the dispatcher's tracked-idle invariant is the same balance snapshot, so it is
    ///         blind to an allowance grant and needs the same schedule-time guard.
    function testShouldBlockDispatcherRescueGrantingAllowanceOverTrackedAsset() public {
        _compose(keccak256("tracked"), 100e6);
        bytes memory callData = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueProtectedTokenCall.selector,
                address(usdc),
                IERC20.approve.selector
            )
        );
        dispatcher.scheduleRescue(address(usdc), 0, callData);

        assertEq(usdc.allowance(address(dispatcher), admin), 0, "no allowance over tracked asset");
        assertEq(dispatcher.trackedIdle(), 100e6, "tracked idle unchanged");
    }

    // ---------------------------------------------------------------------
    // IL-8251 — timelocked admin recall of tracked idle
    // ---------------------------------------------------------------------

    /// @notice The generic rescue cannot take tracked idle (see above); the admin recall can, after the
    ///         rescue delay, without touching the Stargate pool or the LayerZero endpoint.
    function testShouldRecallTrackedIdleToAdmin() public {
        _compose(keccak256("tracked"), 100e6);
        uint64 versionBefore = dispatcher.stateVersion();
        uint256 sendsBefore = endpoint.sentCount();

        vm.prank(admin);
        uint256 recallId = dispatcher.scheduleAdminRecall(60e6);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        dispatcher.executeAdminRecall(recallId, 60e6);

        assertEq(usdc.balanceOf(admin), 60e6, "rescue admin received the recalled idle");
        assertEq(usdc.balanceOf(address(dispatcher)), 40e6, "remainder stays on the dispatcher");
        assertEq(dispatcher.trackedIdle(), 40e6, "tracked idle debited");
        assertEq(dispatcher.observation().trackedIdle, 40e6, "observation follows the debit");
        assertEq(dispatcher.stateVersion(), versionBefore, "recall leaves the state version unchanged");
        assertEq(endpoint.sentCount(), sendsBefore, "no LayerZero message sent");

        // The floor now sits at the remainder: a generic rescue still cannot take any of it.
        bytes memory callData = abi.encodeCall(IERC20.transfer, (admin, 1));
        vm.prank(admin);
        uint256 rescueId = dispatcher.scheduleRescue(address(usdc), 0, callData);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueLedgerInvariantViolation.selector,
                uint256(40e6 - 1),
                uint256(40e6)
            )
        );
        dispatcher.executeRescue(rescueId, callData);
    }

    function testShouldClampAdminRecallToTrackedIdle() public {
        _compose(keccak256("tracked"), 100e6);
        usdc.mint(address(dispatcher), 5e6); // untracked donation is not part of the recall

        vm.prank(admin);
        uint256 recallId = dispatcher.scheduleAdminRecall(150e6);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        dispatcher.executeAdminRecall(recallId, 150e6);

        assertEq(usdc.balanceOf(admin), 100e6, "only the tracked idle was recalled");
        assertEq(dispatcher.trackedIdle(), 0, "tracked idle drained");
        assertEq(usdc.balanceOf(address(dispatcher)), 5e6, "surplus left for the generic rescue");
    }

    function testShouldGateAdminRecallOnAdminTimelockCommitmentAndVeto() public {
        _compose(keccak256("tracked"), 100e6);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        dispatcher.scheduleAdminRecall(1e6);

        vm.prank(admin);
        uint256 recallId = dispatcher.scheduleAdminRecall(10e6);
        (, , uint64 executableAt, , , , ) = dispatcher.rescues(recallId);

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTimelockNotElapsed.selector,
                recallId,
                block.timestamp,
                executableAt
            )
        );
        dispatcher.executeAdminRecall(recallId, 10e6);

        vm.warp(executableAt);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        dispatcher.executeAdminRecall(recallId, 10e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.ForceResolveCommitmentMismatch.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 11e6);

        vm.prank(guardian);
        dispatcher.vetoAllPendingRescues();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueVetoed.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 10e6);

        assertEq(dispatcher.trackedIdle(), 100e6, "no recall took effect");
        assertEq(usdc.balanceOf(admin), 0, "rescue admin received nothing");
    }

    /// @notice With nothing idle the recall clamps to zero: it moves no tokens and only consumes the record.
    function testShouldRecallNothingWithoutTrackedIdle() public {
        usdc.mint(address(dispatcher), 5e6); // untracked surplus is not part of the recall
        vm.prank(admin);
        uint256 recallId = dispatcher.scheduleAdminRecall(10e6);
        vm.warp(block.timestamp + RESCUE_DELAY);

        vm.prank(admin);
        dispatcher.executeAdminRecall(recallId, 10e6);
        assertEq(usdc.balanceOf(admin), 0, "nothing recalled");
        assertEq(usdc.balanceOf(address(dispatcher)), 5e6, "surplus untouched");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueAlreadyConsumed.selector, recallId));
        dispatcher.executeAdminRecall(recallId, 10e6);
    }

    // ---------------------------------------------------------------------
    // Delivery helpers (Origin uses the dispatcher's own address as the same-address peer)
    // ---------------------------------------------------------------------

    function _peer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(dispatcher))));
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(address(dispatcher), EXECUTOR_EID, _peer(), GUID, envelope_);
    }

    function _updateVaults(bytes32 commandId_, uint64 sequence_, uint64 newEpoch_, address[] memory vaults_) internal {
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: commandId_,
                    sequence: sequence_,
                    newConfigEpoch: newEpoch_,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults_
                })
            )
        );
    }

    function _command(bytes32 commandId_, uint64 sequence_, uint8 action_, bytes memory actionData_) internal {
        // A real executor stamps the command with its mirrored config epoch (lockstep with the dispatcher);
        // use the dispatcher's current epoch so the P2 business-command epoch binding is satisfied.
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: commandId_,
                    sequence: sequence_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: action_,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: actionData_
                })
            )
        );
    }

    function _deposit(
        bytes32 commandId_,
        uint64 sequence_,
        address vault_,
        uint256 amtSD_,
        uint256 minShares_
    ) internal {
        _command(
            commandId_,
            sequence_,
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(vault_, amtSD_, minShares_)
        );
    }

    /// @notice Simulate an inbound Stargate credit: mint the physical tokens then deliver the compose.
    function _compose(bytes32 transferId_, uint256 amountLD_) internal {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _allowVault(address v_) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = v_;
        _updateVaults(keccak256("uv"), 0, 1, vaults); // sequence 0, epoch 0 -> 1
    }

    function _lastSentType() internal view returns (MsgType) {
        (MsgType t, ) = _decode(endpoint.lastMessage());
        return t;
    }

    function _decode(bytes memory raw_) internal pure returns (MsgType, bytes memory) {
        (uint8 version, uint8 rawType, bytes memory data) = abi.decode(raw_, (uint8, uint8, bytes));
        version;
        return (MsgType(rawType), data);
    }

    // ---------------------------------------------------------------------
    // UPDATE_VAULTS
    // ---------------------------------------------------------------------

    function testShouldApplyUpdateVaultsAndAdvanceConfigEpoch() public {
        _allowVault(address(vault));
        assertTrue(dispatcher.isAllowedVault(address(vault)), "vault allowed");
        assertEq(dispatcher.commandConfigEpoch(), 1, "config epoch advanced");
        assertEq(dispatcher.nextCommandSequence(), 1, "sequence advanced");
        assertEq(dispatcher.stateVersion(), 0, "state version unchanged: a command moves no value (IL-8257)");
        assertEq(uint8(_lastSentType()), uint8(MsgType.ACK), "ACK sent");
    }

    function testShouldNackUpdateVaultsWithWrongConfigEpoch() public {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _updateVaults(keccak256("uv"), 0, 2, vaults); // epoch should be 1, not 2
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("uv"))),
            uint8(CommandStatus.FAILED),
            "config epoch mismatch fails"
        );
        assertEq(uint8(_lastSentType()), uint8(MsgType.NACK), "NACK sent");
        assertEq(dispatcher.commandConfigEpoch(), 0, "epoch unchanged");
    }

    function testShouldNackUpdateVaultsWithForeignAsset() public {
        MockERC20 dai = new MockERC20("DAI", "DAI", 18);
        MockRemoteVault badVault = new MockRemoteVault(IERC20(address(dai)), "Bad", "BAD");
        address[] memory vaults = new address[](1);
        vaults[0] = address(badVault);
        _updateVaults(keccak256("uv"), 0, 1, vaults);
        assertEq(uint8(dispatcher.commandStatus(keccak256("uv"))), uint8(CommandStatus.FAILED), "asset mismatch fails");
        assertEq(uint8(_lastSentType()), uint8(MsgType.NACK));
    }

    // ---------------------------------------------------------------------
    // Inbound compose -> trackedIdle + TRANSFER_SETTLED
    // ---------------------------------------------------------------------

    function testShouldCreditTrackedIdleOnComposeAndSettle() public {
        _compose(keccak256("t1"), 100e6);
        assertEq(dispatcher.trackedIdle(), 100e6, "tracked idle credited");
        assertEq(dispatcher.stateVersion(), 1, "state version bumped");
        assertTrue(dispatcher.transferSettled(keccak256("t1")), "transfer marked settled");
        assertEq(uint8(_lastSentType()), uint8(MsgType.TRANSFER_SETTLED), "settlement receipt sent");
    }

    function testShouldNoopOnDuplicateInboundCompose() public {
        _compose(keccak256("t1"), 100e6);
        uint256 before = dispatcher.trackedIdle();
        _compose(keccak256("t1"), 100e6); // duplicate
        assertEq(dispatcher.trackedIdle(), before, "no double credit");
    }

    function testShouldRevertWholeComposeWhenCannotFundReceipt() public {
        vm.deal(address(dispatcher), 0); // no native budget for the settlement receipt
        usdc.mint(address(dispatcher), 100e6);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(
            OutboundTransfer({transferId: keccak256("t1")})
        );
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, 100e6, envelope);
        vm.expectRevert(); // InsufficientNativeBudget bubbles; the whole compose reverts atomically
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
        assertEq(dispatcher.trackedIdle(), 0, "accounting not partially settled");
    }

    // ---------------------------------------------------------------------
    // DEPOSIT / REDEEM measured deltas + slippage
    // ---------------------------------------------------------------------

    function testShouldDepositMeasuredDelta() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0);

        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(dispatcher.trackedIdle(), 50e6, "idle reduced by measured asset spend");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "dispatcher holds shares");
        assertTrue(dispatcher.isTrackedVault(address(vault)), "vault now tracked");
        assertEq(dispatcher.nextCommandSequence(), 2);
    }

    function testShouldNackDepositOnSlippage() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 999e6); // minShares unreachable

        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED));
        assertEq(uint8(_lastSentType()), uint8(MsgType.NACK));
        assertEq(dispatcher.nextCommandSequence(), 1, "sequence not advanced on failure");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle untouched on failed deposit");
    }

    function testShouldNackDepositToNonAllowedVault() public {
        _compose(keccak256("t1"), 100e6); // funded but no allowlist
        _deposit(keccak256("dep"), 0, address(vault), 50e6, 0);
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED));
    }

    function testShouldRedeemMeasuredDelta() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // shares 50e6, idle 50e6

        _command(
            keccak256("red"),
            2,
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(vault), 20e6, 0)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("red"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(dispatcher.trackedIdle(), 70e6, "idle increased by redeemed assets");
        assertEq(vault.balanceOf(address(dispatcher)), 30e6, "shares reduced");
    }

    // ---------------------------------------------------------------------
    // Async: REQUEST_SHARES post-fee outstanding request + REDEEM_FROM_REQUEST
    // ---------------------------------------------------------------------

    /// @dev Deploys a `MockRemotePlasmaVault` and wires a `MockWithdrawManager` as its GENUINE manager via
    ///      `setWithdrawManager` (IL-8117 plan §3.3 item 3), so the vault's `UniversalReader.read` answers
    ///      the dispatcher's manager cross-check honestly. Used by the mock-fee tests below and by the
    ///      untracked-vault guard test (T1), whose fixture must answer the cross-check so G1 alone decides
    ///      the outcome (plan §5) rather than being masked by a `read` revert.
    function _mockWm() private returns (MockWithdrawManager wm, MockRemotePlasmaVault rv) {
        rv = new MockRemotePlasmaVault(IERC20(address(usdc)), "Mock WM Vault", "MWVLT");
        wm = new MockWithdrawManager(address(rv));
        rv.setWithdrawManager(address(wm));
    }

    function testShouldRecordPostFeeOutstandingRequestShares() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        wm.setFeeBps(1000); // 10% withdraw-manager fee
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.SUCCEEDED));
        // 10e6 requested, 10% fee -> the manager stores 9e6 outstanding, NOT the 10e6 input.
        assertEq(wm.requestInfo(address(dispatcher)).shares, 9e6, "manager holds the post-fee outstanding request");
    }

    function _requestWithFee(
        uint256 feeShares_,
        uint256 maxFee_,
        bytes32 id_
    ) private returns (MockRemotePlasmaVault rv, MockWithdrawManager wm) {
        (wm, rv) = _mockWm();
        wm.setFeeShares(feeShares_);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        _command(
            id_,
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, maxFee_)
        );
    }

    function testShouldNackRequestSharesWhenFeeExceedsCeiling() public {
        (MockRemotePlasmaVault rv, MockWithdrawManager wm) = _requestWithFee(2e6, 1e6, keccak256("req"));
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(rv.balanceOf(address(dispatcher)), 50e6, "fee transfer rolled back");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "no request recorded");
    }

    function testShouldSucceedRequestSharesWithinCeiling() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        wm.setFeeShares(1e6);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit SharesRequested(address(rv), 10e6, 1e6);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, 1e6)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.SUCCEEDED));
    }

    function testShouldSucceedRequestSharesWithNoCeiling() public {
        _requestWithFee(5e6, type(uint256).max, keccak256("req"));
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.SUCCEEDED));
    }

    function testShouldNackRequestSharesWithZeroCeilingWhenAnyFeeTaken() public {
        _requestWithFee(1, 0, keccak256("req"));
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.FAILED));
    }

    function testShouldNackRequestSharesExceedingShareBalance() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0); // dispatcher holds 50e6 vault shares
        assertEq(rv.withdrawManager(), address(wm), "manager cross-check passes before the balance bound rejects");
        // §8 P3 item 3: requesting more shares than the dispatcher actually holds is rejected (NACK).
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 60e6, type(uint256).max)
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("req"))),
            uint8(CommandStatus.FAILED),
            "over-balance request NACKed"
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "no request recorded");
    }

    function testShouldRedeemFromRequest() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 10e6);

        uint256 idleBefore = dispatcher.trackedIdle();
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 10e6, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("rfr"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(dispatcher.trackedIdle(), idleBefore + 10e6, "assets added to idle");
    }

    function testShouldNackRedeemFromRequestToWrongReceiver() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, type(uint256).max)
        );
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 10e6, 0, address(0xBEEF))
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("rfr"))),
            uint8(CommandStatus.FAILED),
            "receiver must be self"
        );
    }

    // ---------------------------------------------------------------------
    // IL-8118: the REAL WithdrawManager REPLACES the stored request on every requestShares; a repeated or
    // shrinking request must succeed and leave exactly the manager's new value (IL-8410: the dispatcher no
    // longer keeps a copy, so the manager and the SharesRequested event are the observable truth).
    // ---------------------------------------------------------------------

    /// @dev Deploys a real `WithdrawManager` behind a permissive authority, wired to a fresh
    ///      `MockRemotePlasmaVault`, with the given WAD-scale request fee. Asserts the fee actually landed
    ///      so the scale is pinned in the test itself (plan §3.1).
    function _realWm(uint256 feeWad_) private returns (WithdrawManager wm, MockRemotePlasmaVault rv) {
        MockPermissiveAuthority authority = new MockPermissiveAuthority();
        wm = new WithdrawManager(address(authority));
        rv = new MockRemotePlasmaVault(IERC20(address(usdc)), "Real Vault", "RVLT");
        rv.setWithdrawManager(address(wm));
        wm.updatePlasmaVaultAddress(address(rv));
        wm.updateWithdrawWindow(1 days);
        if (feeWad_ > 0) {
            wm.updateRequestFee(feeWad_);
        }
        assertEq(wm.getRequestFee(), feeWad_, "fee scale pinned in the test");
    }

    function testShouldReplaceRealWithdrawManagerRequestAfterSecondRequestWithFee() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16); // 1% WAD fee
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        _command(
            keccak256("req1"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 50e6, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req1"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(wm.requestInfo(address(dispatcher)).shares, 49_500_000, "manager after request 1");
        assertEq(rv.balanceOf(address(dispatcher)), 49_500_000, "dispatcher balance net of fee");
        assertEq(rv.balanceOf(address(wm)), 500_000, "fee shares moved to the manager");

        _command(
            keccak256("req2"),
            3,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 49_500_000, type(uint256).max)
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("req2"))),
            uint8(CommandStatus.SUCCEEDED),
            "re-request after a fee-bearing full request must not revert"
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 49_005_000, "manager after request 2");
        assertEq(rv.balanceOf(address(dispatcher)), 49_005_000, "dispatcher balance net of both fees");
    }

    function testShouldReplaceRealWithdrawManagerRequestWhenRequestShrinks() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0); // no fee: R_new = shares_ exactly
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 30e6, 0);

        _command(
            keccak256("req1"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 30e6, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 30e6);

        _command(
            keccak256("req2"),
            3,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 10e6, type(uint256).max) // shrinks
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("req2"))),
            uint8(CommandStatus.SUCCEEDED),
            "a shrinking re-request must not revert"
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 10e6, "manager request replaced by the shrink");
    }

    function testShouldEmitOutstandingRequestOnRepeatedRequest() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        _command(
            keccak256("req1"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 50e6, type(uint256).max)
        );

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit SharesRequested(address(rv), 49_005_000, 495_000);
        _command(
            keccak256("req2"),
            3,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 49_500_000, type(uint256).max)
        );
    }

    /// @dev Guard: the manager request closes exactly through the `REDEEM_FROM_REQUEST` ->
    ///      `canWithdrawFromRequest` path over real integer arithmetic.
    function testShouldCloseRealWithdrawManagerRequestThroughRedeemFromRequest() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0); // dispatcher holds 50e6 rv shares

        uint256 requestTs = block.timestamp;
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e6, type(uint256).max)
        );
        uint256 pending = wm.requestInfo(address(dispatcher)).shares; // 19_800_000 (1% fee)
        assertEq(pending, 19_800_000, "post-fee request");
        assertEq(rv.balanceOf(address(dispatcher)), 49_800_000, "balance net of the one fee charged so far");

        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, pending);

        uint256 idleBefore = dispatcher.trackedIdle();
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), pending, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("rfr"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "manager request closed");
        assertEq(dispatcher.trackedIdle(), idleBefore + pending, "assets moved to idle 1:1 (mock vault)");
        assertEq(rv.balanceOf(address(dispatcher)), 30_000_000, "remaining balance after the redeem-from-request");
        assertTrue(dispatcher.isTrackedVault(address(rv)), "non-zero balance keeps the vault tracked");
    }

    /// @dev Guard: a request does not move NAV beyond the fee; `observation()` prices the position from
    ///      `balanceOf` alone.
    function testShouldValueObservationFromBalanceOfOnly() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        uint256 assetsBefore = dispatcher.observation().vaultAssetValues[0];
        assertEq(assetsBefore, rv.convertToAssets(rv.balanceOf(address(dispatcher))), "observation prices balanceOf");

        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 50e6, type(uint256).max)
        );
        uint256 feeAmount = 500_000; // 1% of 50e6
        uint256 assetsAfter = dispatcher.observation().vaultAssetValues[0];
        assertEq(
            assetsAfter,
            rv.convertToAssets(rv.balanceOf(address(dispatcher))),
            "still values the vault position from balanceOf alone"
        );
        assertEq(assetsBefore - assetsAfter, rv.convertToAssets(feeAmount), "NAV moved by exactly the fee");
    }

    /// @dev IL-8410 / IL-8336 regression: a direct REDEEM of the full share balance untracks the vault even
    ///      though the WithdrawManager still reports an outstanding request (the request cannot be exercised
    ///      without shares). Pre-fix the request cache pinned the vault in the tracked set forever.
    function testShouldUntrackVaultAfterDirectRedeemDespiteOutstandingRequest() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(1e16);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e6, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 19_800_000, "request outstanding");
        uint256 balance = rv.balanceOf(address(dispatcher));
        assertEq(balance, 49_800_000, "balance net of the request fee");

        _command(
            keccak256("red"),
            3,
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(rv), balance, 0)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("red"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(rv.balanceOf(address(dispatcher)), 0, "share balance drained");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 19_800_000, "manager still reports the request");
        assertFalse(dispatcher.isTrackedVault(address(rv)), "vault untracked, slot freed");
        assertEq(dispatcher.getTrackedVaults().length, 0, "tracked set empty");
    }

    /// @dev IL-8410 / IL-8336: REDEEM_FROM_REQUEST above the manager's request fails (dispatcher no longer
    ///      pre-checks; the vault reverts via `canWithdrawFromRequest`) even with the window open and funds
    ///      released, and nothing moves.
    function testShouldNackRedeemFromRequestAboveManagerRequest() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);
        uint256 requestTs = block.timestamp;
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e6, type(uint256).max)
        );
        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 20e6);

        uint256 idleBefore = dispatcher.trackedIdle();
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 20e6 + 1, 0, address(dispatcher))
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("rfr"))),
            uint8(CommandStatus.FAILED),
            "above-request NACKed"
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e6, "request unchanged");
        assertEq(rv.balanceOf(address(dispatcher)), 50e6, "share balance unchanged");
        assertEq(dispatcher.trackedIdle(), idleBefore, "no assets credited");
    }

    // ---------------------------------------------------------------------
    // IL-8117: the missing `isTrackedVault` guard on `_redeemFromRequest` (G1), and the self-attested
    // withdraw-manager check on `_requestShares` / `_redeemFromRequest` (G2, G3), replaced by an
    // authoritative `UniversalReader.read` of the vault's own configured manager. Each test isolates one
    // guard; the re-injection proof in the cycle file confirms this per guard (plan §5).
    // ---------------------------------------------------------------------

    /// @dev Guard G1. Fixture is deliberately `_mockWm()` (a vault that ANSWERS the manager cross-check)
    ///      rather than the plain `MockRemoteVault`: with no `read` at all, the cross-check would revert on
    ///      its own and mask G1's absence, so this fixture is required to isolate G1 (plan §5).
    function testShouldNackRedeemFromRequestOnUntrackedVault() public {
        (MockWithdrawManager wm, MockRemotePlasmaVault rv) = _mockWm();
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        // No deposit: `rv` is allowlisted but was never entered into the tracked-position set.
        _command(
            keccak256("rfr"),
            1,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(rv), 0, 0, address(dispatcher))
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("rfr"))),
            uint8(CommandStatus.FAILED),
            "untracked vault NACKed"
        );
        assertEq(dispatcher.nextCommandSequence(), 1, "sequence not advanced on failure");
        assertFalse(dispatcher.isTrackedVault(address(rv)), "still not tracked");
        assertEq(dispatcher.trackedIdle(), 100e6, "idle untouched");
    }

    /// @dev Guard G2: a manager that self-attests `rv` but is not `rv`'s configured manager is rejected.
    function testShouldNackRequestSharesFromForeignWithdrawManager() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        MockWithdrawManager fake = new MockWithdrawManager(address(rv)); // self-attests rv; not rv's manager
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(fake), address(rv), 10e6, type(uint256).max)
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("req"))),
            uint8(CommandStatus.FAILED),
            "foreign manager NACKed"
        );
        assertEq(rv.balanceOf(address(dispatcher)), 50e6, "no fee moved");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 0, "real manager saw nothing");
    }

    /// @dev Guard G3, on the vault's own genuine request: a foreign manager named on REDEEM_FROM_REQUEST is
    ///      rejected even though (per plan §2.4) the vault would enforce its own manager regardless — this
    ///      is a consistency check, proven independently of G2.
    function testShouldNackRedeemFromRequestFromForeignWithdrawManager() public {
        (WithdrawManager wm, MockRemotePlasmaVault rv) = _realWm(0);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        uint256 requestTs = block.timestamp;
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(rv), 20e6, type(uint256).max)
        );
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e6);

        vm.warp(requestTs + 2);
        vm.prank(address(dispatcher));
        wm.releaseFunds(requestTs + 1, 20e6);

        MockWithdrawManager fake = new MockWithdrawManager(address(rv)); // self-attests rv; not rv's manager
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(fake), address(rv), 20e6, 0, address(dispatcher))
        );
        assertEq(
            uint8(dispatcher.commandStatus(keccak256("rfr"))),
            uint8(CommandStatus.FAILED),
            "foreign manager NACKed"
        );
        assertEq(rv.balanceOf(address(dispatcher)), 50e6, "balance untouched");
        assertEq(wm.requestInfo(address(dispatcher)).shares, 20e6, "real manager request untouched");
    }

    /// @dev Consequence of G2 (assessment §3): a foreign manager cannot pin a fully-redeemed vault in the
    ///      tracked set; the request itself NACKs, so the vault untracks normally. The second command's
    ///      sequence is read LIVE off `nextCommandSequence()` because it differs pre-/post-fix (the first
    ///      command consumes a sequence only when it succeeds); hard-coding either value would make the other
    ///      case revert `SequenceGap` on delivery, a setup error rather than this test's own assertion.
    function testShouldNotPinVaultThroughForeignWithdrawManager() public {
        (, MockRemotePlasmaVault rv) = _realWm(0);
        _allowVault(address(rv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(rv), 50e6, 0);

        MockWithdrawManager fake = new MockWithdrawManager(address(rv));
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(fake), address(rv), 50e6, type(uint256).max)
        );

        _command(
            keccak256("red"),
            dispatcher.nextCommandSequence(),
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(rv), 50e6, 0)
        );

        assertFalse(dispatcher.isTrackedVault(address(rv)), "vault not pinned");
        assertEq(dispatcher.getTrackedVaults().length, 0, "tracked set empty");
    }

    // ---------------------------------------------------------------------
    // Sequencing
    // ---------------------------------------------------------------------

    function testShouldRevertOnSequenceGap() public {
        _allowVault(address(vault)); // nextCommandSequence now 1
        _compose(keccak256("t1"), 100e6);
        // Build the gap command inline (read the epoch BEFORE expectRevert so the only call in the
        // expectRevert window is the reverting delivery itself).
        bytes memory envelope = CrosschainMessages.encodeCommand(
            Command({
                commandId: keccak256("dep"),
                sequence: 2,
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
            })
        );
        // A command at sequence 2 (gap) reverts so LayerZero retains the packet for retry.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.SequenceGap.selector, uint64(1), uint64(2)));
        _deliver(envelope);
    }

    function testShouldNoopOnResolvedCommandRedelivery() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // SUCCEEDED, nextCommandSequence 2
        // Re-delivery of the same (now-SUCCEEDED) command is a no-op, not a SequenceGap.
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0);
        assertEq(dispatcher.trackedIdle(), 50e6, "no re-execution");
        assertEq(dispatcher.nextCommandSequence(), 2);
    }

    function testShouldRejectRedeliveryWithModifiedActionData() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // SUCCEEDED
        // Re-deliver the SAME command id + sequence but with DIFFERENT action data: must revert on the
        // commitment mismatch and never overwrite the stored work (§9 P2 item 4).
        bytes memory envelope = CrosschainMessages.encodeCommand(
            Command({
                commandId: keccak256("dep"),
                sequence: 1,
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 25e6, 0) // changed amount
            })
        );
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandCommitmentMismatch.selector, keccak256("dep")));
        _deliver(envelope);
    }

    function testShouldRejectRedeliveryOfFailedWithModifiedData() public {
        _allowVault(address(vault));
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // FAILED (no idle)
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED));
        // A FAILED command must not be silently replaced by a different payload under the same id.
        bytes memory envelope = CrosschainMessages.encodeCommand(
            Command({
                commandId: keccak256("dep"),
                sequence: 1,
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 1e6, 0)
            })
        );
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandCommitmentMismatch.selector, keccak256("dep")));
        _deliver(envelope);
    }

    function testShouldNackBusinessCommandWithStaleConfigEpoch() public {
        _allowVault(address(vault)); // dispatcher.commandConfigEpoch == 1
        _compose(keccak256("t1"), 100e6);
        // A DEPOSIT stamped with a stale epoch (0) is rejected inside the self-call -> FAILED + NACK.
        bytes memory envelope = CrosschainMessages.encodeCommand(
            Command({
                commandId: keccak256("dep"),
                sequence: 1,
                commandConfigEpoch: 0, // stale (current is 1)
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
            })
        );
        _deliver(envelope);
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED), "stale epoch NACKed");
        assertEq(uint8(_lastSentType()), uint8(MsgType.NACK));
        assertEq(dispatcher.trackedIdle(), 100e6, "idle untouched by rejected command");
    }

    function testShouldNackBusinessCommandWithFutureConfigEpoch() public {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        bytes memory envelope = CrosschainMessages.encodeCommand(
            Command({
                commandId: keccak256("dep"),
                sequence: 1,
                commandConfigEpoch: 2, // future (current is 1)
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: CrosschainMessages.encodeDepositAction(address(vault), 50e6, 0)
            })
        );
        _deliver(envelope);
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED), "future epoch NACKed");
    }

    function testShouldEnforceExecutorChainBindingOnHappyPath() public {
        // The dispatcher accepts messages only from its single executor chain/EID; delivery on the
        // registered peer resolves srcChainId == EXECUTOR_CHAIN_ID (the base maps EID -> chain).
        _allowVault(address(vault));
        assertEq(dispatcher.EXECUTOR_CHAIN_ID(), EXECUTOR_CHAIN, "bound to the single executor chain");
    }

    // ---------------------------------------------------------------------
    // Recall lane: RETURN_ASSETS / RETRY / CANCEL
    // ---------------------------------------------------------------------

    function _returnRequest(bytes32 requestId_, uint256 amtSD_, uint256 maxSD_, uint256 minSD_) internal {
        _deliver(
            CrosschainMessages.encodeReturnAssetsRequest(
                ReturnAssetsRequest({
                    requestId: requestId_,
                    amountSD: amtSD_,
                    maxAccountedSD: maxSD_,
                    minReturnSD: minSD_
                })
            )
        );
    }

    function testShouldReturnAssetsOnRecallLane() public {
        _compose(keccak256("t1"), 100e6); // trackedIdle 100e6, backed by 100e6 USDC
        _returnRequest(keccak256("r1"), 40e6, 40e6, 0);

        assertEq(dispatcher.trackedIdle(), 60e6, "idle debited by returned amount");
        assertTrue(dispatcher.recallConsumed(keccak256("r1")), "recall consumed");
        assertEq(uint8(_lastSentType()), uint8(MsgType.RETURN_STARTED), "return metadata sent");
        MockStargatePool.Send memory sent = pool.lastSend();
        bytes memory expected = OptionsBuilder
            .newOptions()
            .addExecutorLzReceiveOption(250_000, 0)
            .addExecutorLzComposeOption(0, 1_500_000, 0);
        assertEq(sent.extraOptions, expected, "return carries mandatory automatic compose gas");
    }

    function testShouldRejectRecallWithoutTrackedIdle() public {
        bytes32 requestId = keccak256("zero-idle");
        _returnRequest(requestId, 40e6, 40e6, 0);

        assertEq(dispatcher.trackedIdle(), 0, "no remote value moved");
        assertTrue(dispatcher.recallConsumed(requestId), "rejection is terminal and idempotent");
        assertEq(uint8(_lastSentType()), uint8(MsgType.RETURN_REJECTED), "authenticated rejection sent");
    }

    /// @notice IL-8119: a recall clamped below the manager's floor by `maxAccountedSD` (not by tracked
    ///         idle) must be rejected terminally instead of forwarding the unclamped floor to the pool.
    ///         request=100e6, accounted bound=30e6, idle=100e6 -> sendLD = min(100e6,30e6,100e6) = 30e6,
    ///         which is below the 31e6 floor: the pool must never be called.
    function testShouldRejectRecallBelowFloorWithBelowMinimumReason() public {
        _compose(keccak256("t1"), 100e6); // trackedIdle = 100e6, not the binding term here
        bytes32 requestId = keccak256("below-floor");

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit ReturnAssetsRejected(requestId, uint8(ReturnRejectReason.BELOW_MINIMUM));
        _returnRequest(requestId, 100e6, 30e6, 31e6);

        assertTrue(dispatcher.recallConsumed(requestId), "rejection is terminal");
        assertEq(dispatcher.trackedIdle(), 100e6, "no value moved: the accounting clamp bound the send");
        assertEq(pool.sendCount(), 0, "the pool is never called on a below-floor rejection");

        (MsgType mt, bytes memory data) = _decode(endpoint.lastMessage());
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED), "authenticated rejection sent");
        ReturnRejected memory rej = CrosschainMessages.decodeReturnRejected(data);
        assertEq(rej.requestId, requestId);
        assertEq(uint8(rej.reason), uint8(ReturnRejectReason.BELOW_MINIMUM));
    }

    function testShouldNoopOnDuplicateReturnRequest() public {
        _compose(keccak256("t1"), 100e6);
        _returnRequest(keccak256("r1"), 40e6, 40e6, 0);
        uint256 idle = dispatcher.trackedIdle();
        _returnRequest(keccak256("r1"), 40e6, 40e6, 0); // duplicate
        assertEq(dispatcher.trackedIdle(), idle, "idempotent no-op");
    }

    /// @notice IL-8452: a recall that meets the floor before the pool fee but would be credited below it is
    ///         rejected terminally (BELOW_MINIMUM) instead of reverting in `sendToken` and retaining the packet.
    /// @dev FAILS WITHOUT THE FIX: the pool reverts `SlippageExceeded`, so the whole `lzReceive` reverts.
    function testShouldRejectRecallWhosePoolCreditFallsBelowFloor() public {
        _compose(keccak256("t1"), 100e6);
        pool.setFeeBps(2000); // 20% haircut -> credited 32e6 for a 40e6 send
        bytes32 requestId = keccak256("r1");

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit ReturnAssetsRejected(requestId, uint8(ReturnRejectReason.BELOW_MINIMUM));
        _returnRequest(requestId, 40e6, 40e6, 39e6); // 40e6 meets the 39e6 floor, the 32e6 credit does not

        assertTrue(dispatcher.recallConsumed(requestId), "rejection is terminal; a re-delivery is a no-op");
        assertEq(dispatcher.trackedIdle(), 100e6, "no idle debited");
        assertEq(pool.sendCount(), 0, "nothing sent to the pool");
        assertEq(usdc.allowance(address(dispatcher), address(pool)), 0, "no allowance left behind");

        (MsgType mt, bytes memory data) = _decode(endpoint.lastMessage());
        assertEq(uint8(mt), uint8(MsgType.RETURN_REJECTED), "authenticated rejection sent");
        ReturnRejected memory rej = CrosschainMessages.decodeReturnRejected(data);
        assertEq(rej.requestId, requestId);
        assertEq(uint8(rej.reason), uint8(ReturnRejectReason.BELOW_MINIMUM));
    }

    /// @notice IL-8452 control: a pool fee that still leaves the credit at or above the floor sends normally.
    function testShouldSendRecallWhenPoolCreditMeetsFloorAfterFee() public {
        _compose(keccak256("t1"), 100e6);
        pool.setFeeBps(2000); // 40e6 send -> 32e6 credited
        bytes32 requestId = keccak256("r1");

        _returnRequest(requestId, 40e6, 40e6, 32e6); // floor exactly at the credit

        assertTrue(dispatcher.recallConsumed(requestId));
        assertEq(dispatcher.trackedIdle(), 60e6, "sent amount debited");
        assertEq(pool.sendCount(), 1, "sent through the pool");
        (MsgType mt, ) = _decode(endpoint.lastMessage());
        assertEq(uint8(mt), uint8(MsgType.RETURN_STARTED));
    }

    function testShouldRetryFailedCommandToSuccess() public {
        _allowVault(address(vault)); // sequence 0 -> 1
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // fails: trackedIdle == 0
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED));

        _compose(keccak256("t1"), 100e6); // now fund idle
        _deliver(
            CrosschainMessages.encodeRetryCommand(RetryCommand({commandId: keccak256("dep"), minExecutionGas: 0}))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.SUCCEEDED), "retry succeeds");
        assertEq(dispatcher.trackedIdle(), 50e6);
    }

    function testShouldRejectRetryUnknownCommand() public {
        // Unknown command id -> CommandNotFound (the whole lzReceive reverts; LZ would retain the packet).
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandNotFound.selector, keccak256("nope")));
        _deliver(
            CrosschainMessages.encodeRetryCommand(RetryCommand({commandId: keccak256("nope"), minExecutionGas: 0}))
        );
    }

    function testShouldCancelFailedCommand() public {
        _allowVault(address(vault));
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0); // fails (no idle)
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.FAILED));

        _deliver(CrosschainMessages.encodeCancelCommand(CancelCommand({commandId: keccak256("dep")})));
        assertEq(uint8(dispatcher.commandStatus(keccak256("dep"))), uint8(CommandStatus.CANCELLED), "cancelled");
        assertEq(dispatcher.nextCommandSequence(), 2, "cancel advances one sequence");
        assertEq(uint8(_lastSentType()), uint8(MsgType.ACK), "cancel resolution receipt sent");
    }

    // ---------------------------------------------------------------------
    // IL-8555 / IL-8556 rescue fences (dispatcher side)
    // ---------------------------------------------------------------------

    function _trackVaultWithShares() internal {
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0);
        assertTrue(dispatcher.isTrackedVault(address(vault)), "vault tracked");
    }

    function testShouldBlockRescueApproveOnTrackedVaultShares() public {
        _trackVaultWithShares();
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.scheduleRescue(address(vault), 0, cd);
        assertEq(vault.allowance(address(dispatcher), admin), 0, "no share allowance");
    }

    /// @notice IL-8770: the ContextManager `runWithContext` selector is rejected on ANY target, so the host can
    ///         never become the context sender of a vault `approve`. `abi.encodeCall` pins the selector.
    function testShouldBlockRescueRunWithContextOnAnyTarget() public {
        _trackVaultWithShares();
        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        bytes[] memory datas = new bytes[](1);
        datas[0] = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        bytes memory cd = abi.encodeCall(
            ContextManager.runWithContext,
            (ExecuteData({targets: targets, datas: datas}))
        );
        address contextManager = address(0xC0C0);
        uint256 countBefore = dispatcher.rescueCount();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueContextCall.selector, contextManager));
        dispatcher.scheduleRescue(contextManager, 0, cd);
        assertEq(dispatcher.rescueCount(), countBefore, "nothing queued");
        assertEq(vault.allowance(address(dispatcher), admin), 0, "no share allowance");
    }

    function testShouldBlockRescueRedeemOnTrackedVault() public {
        _trackVaultWithShares();
        bytes memory cd = abi.encodeWithSignature("redeem(uint256,address,address)", 50e6, admin, address(dispatcher));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.scheduleRescue(address(vault), 0, cd);
    }

    /// @notice A vault untracked at schedule time that becomes tracked during the timelock is rejected at
    ///         execute time.
    function testShouldBlockRescueOnVaultTrackedAfterSchedule() public {
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(vault), 0, cd); // neither allowlisted nor tracked: accepted
        _allowVault(address(vault));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(vault), 50e6, 0);
        assertTrue(dispatcher.isTrackedVault(address(vault)));

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.executeRescue(id, cd);
    }

    /// @notice IL-8784 (reverses the old fence-after-removal rule): a vault dropped from the allowlist is swept into
    ///         idle and untracked in the same command, so the tracked-vault fence no longer covers it and the
    ///         shares are gone from the dispatcher. ALPHA withdraws BEFORE removing a vault with a residual.
    function testShouldSweepAndUntrackVaultDroppedFromAllowlist() public {
        _trackVaultWithShares();
        uint256 idleBefore = dispatcher.trackedIdle();
        _updateVaults(
            keccak256("uv2"),
            dispatcher.nextCommandSequence(),
            dispatcher.commandConfigEpoch() + 1,
            new address[](0)
        );
        assertEq(dispatcher.getAllowedVaults().length, 0, "allowlist emptied");
        assertFalse(dispatcher.isAllowedVault(address(vault)), "vault left the allowlist");
        assertFalse(dispatcher.isTrackedVault(address(vault)), "vault untracked by the sweep");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "shares redeemed");
        assertEq(dispatcher.trackedIdle(), idleBefore + 50e6, "redeemed assets credited to idle");

        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        dispatcher.scheduleRescue(address(vault), 0, cd); // no longer fenced: neither allowlisted nor tracked
    }

    /// @notice An indirect target spending a leftover share allowance passes the target fence; the share
    ///         snapshot catches the decrease.
    function testShouldBlockRescueThatReducesTrackedShares() public {
        _trackVaultWithShares();
        MockSharePuller puller = new MockSharePuller();
        vm.prank(address(dispatcher));
        vault.approve(address(puller), type(uint256).max);
        bytes memory cd = abi.encodeCall(
            MockSharePuller.pull,
            (IERC20(address(vault)), address(dispatcher), admin, 10e6)
        );

        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(puller), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTrackedSharesReduced.selector,
                address(vault),
                uint256(50e6),
                uint256(40e6)
            )
        );
        dispatcher.executeRescue(id, cd);
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "shares intact");
    }

    function testShouldStillAllowRescueLeavingTrackedSharesUnchanged() public {
        _trackVaultWithShares();
        MockSharePuller puller = new MockSharePuller();
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(dispatcher), 5e18);
        bytes memory noopCd = abi.encodeCall(MockSharePuller.noop, ());
        bytes memory otherCd = abi.encodeCall(IERC20.transfer, (admin, 5e18));

        vm.startPrank(admin);
        uint256 id1 = dispatcher.scheduleRescue(address(puller), 0, noopCd);
        uint256 id2 = dispatcher.scheduleRescue(address(other), 0, otherCd);
        vm.stopPrank();
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.startPrank(admin);
        dispatcher.executeRescue(id1, noopCd);
        dispatcher.executeRescue(id2, otherCd);
        vm.stopPrank();
        assertEq(other.balanceOf(admin), 5e18, "unrelated token rescued");
        assertEq(vault.balanceOf(address(dispatcher)), 50e6, "shares unchanged");
    }

    function testShouldBlockDispatcherRescueThroughLzEndpoint() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                CrosschainErrors.RescueTransportCall.selector,
                address(endpoint),
                bytes4(keccak256("setDelegate(address)"))
            )
        );
        dispatcher.scheduleRescue(address(endpoint), 0, abi.encodeWithSignature("setDelegate(address)", admin));
    }

    /// @notice The Stargate pool is banned for ANY call (compose forgery via `sendToken`, IL-8555).
    function testShouldBlockDispatcherRescueOnStargatePool() public {
        bytes memory sendTokenCd = abi.encodeWithSignature("sendToken(bytes,bytes,bytes)", "", "", "");
        vm.startPrank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueTransportCall.selector, address(pool), bytes4(sendTokenCd))
        );
        dispatcher.scheduleRescue(address(pool), 0, sendTokenCd);
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.RescueTransportCall.selector, address(pool), bytes4(0))
        );
        dispatcher.scheduleRescue(address(pool), 0, "");
        vm.stopPrank();
    }

    /// @notice An allowlisted vault that is not yet tracked (no deposit so far) is banned too.
    function testShouldBlockRescueOnAllowlistedUntrackedVault() public {
        _allowVault(address(vault));
        assertFalse(dispatcher.isTrackedVault(address(vault)), "not tracked yet");
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.scheduleRescue(address(vault), 0, cd);
    }

    /// @notice A vault allowlisted AFTER schedule is refused at execute.
    function testShouldBlockRescueOnVaultAllowlistedAfterSchedule() public {
        bytes memory cd = abi.encodeCall(IERC20.approve, (admin, type(uint256).max));
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(vault), 0, cd); // not allowlisted yet: accepted
        _allowVault(address(vault));
        assertFalse(dispatcher.isTrackedVault(address(vault)), "allowlisted but untracked");

        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.RescueTrackedVaultCall.selector, address(vault)));
        dispatcher.executeRescue(id, cd);
    }

    /// @notice At the 32-vault cap the snapshot loop works and a harmless rescue still executes.
    function testShouldExecuteHarmlessRescueAtTrackedVaultCap() public {
        uint256 cap = 32;
        address[] memory vaults = new address[](cap);
        for (uint256 i; i < cap; ++i) {
            vaults[i] = address(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        }
        _updateVaults(keccak256("uv"), 0, 1, vaults);
        _compose(keccak256("t1"), 100e6);
        for (uint256 i; i < cap; ++i) {
            _deposit(keccak256(abi.encode("dep", i)), uint64(i + 1), vaults[i], 1e6, 0);
        }
        assertEq(dispatcher.getTrackedVaults().length, cap, "cap reached");

        MockSharePuller puller = new MockSharePuller();
        bytes memory cd = abi.encodeCall(MockSharePuller.noop, ());
        vm.prank(admin);
        uint256 id = dispatcher.scheduleRescue(address(puller), 0, cd);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        dispatcher.executeRescue(id, cd);
    }

    // ---------------------------------------------------------------------
    // IL-8608: remote vault keeping its withdraw manager in the legacy (pre-IL-6952) slot
    // ---------------------------------------------------------------------

    function _legacyWm() private returns (MockWithdrawManager wm, MockLegacyRemotePlasmaVault lv) {
        lv = new MockLegacyRemotePlasmaVault(IERC20(address(usdc)), "Legacy WM Vault", "LWVLT");
        wm = new MockWithdrawManager(address(lv));
        lv.setLegacyWithdrawManager(address(wm));
        // The corrected ERC-7201 slot is empty on such a vault: a corrected-slot-only read yields address(0).
        ReadResult memory r = lv.read(address(dispatcher), abi.encodeCall(dispatcher.plasmaVaultWithdrawManager, ()));
        assertEq(abi.decode(r.data, (address)), address(wm), "fallback resolves the legacy slot");
    }

    function testShouldRequestSharesAndRedeemFromRequestOnLegacySlotVault() public {
        (MockWithdrawManager wm, MockLegacyRemotePlasmaVault lv) = _legacyWm();
        _allowVault(address(lv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(lv), 50e6, 0);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(wm), address(lv), 10e6, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(wm.requestInfo(address(dispatcher)).shares, 10e6);

        uint256 idleBefore = dispatcher.trackedIdle();
        _command(
            keccak256("rfr"),
            3,
            uint8(BusinessAction.REDEEM_FROM_REQUEST),
            CrosschainMessages.encodeRedeemFromRequestAction(address(wm), address(lv), 10e6, 0, address(dispatcher))
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("rfr"))), uint8(CommandStatus.SUCCEEDED));
        assertEq(dispatcher.trackedIdle(), idleBefore + 10e6, "assets added to idle");
    }

    function testShouldNackZeroWithdrawManagerOnLegacySlotVault() public {
        (, MockLegacyRemotePlasmaVault lv) = _legacyWm();
        _allowVault(address(lv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(lv), 50e6, 0);
        _command(
            keccak256("req"),
            2,
            uint8(BusinessAction.REQUEST_SHARES),
            CrosschainMessages.encodeRequestSharesAction(address(0), address(lv), 10e6, type(uint256).max)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.FAILED), "zero manager NACKed");

        Command memory c = Command({
            commandId: keccak256("req-probe"),
            sequence: 2,
            commandConfigEpoch: dispatcher.commandConfigEpoch(),
            action: uint8(BusinessAction.REQUEST_SHARES),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeRequestSharesAction(address(0), address(lv), 10e6, type(uint256).max)
        });
        vm.prank(address(dispatcher));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WithdrawManagerUnresolved.selector, address(lv)));
        dispatcher.runBusinessSelf(c.commandId, uint8(MsgType.COMMAND), abi.encode(c));
    }

    function testShouldRejectUnresolvedWithdrawManagerWithDedicatedError() public {
        // Manager in NEITHER slot: the vault answers address(0); a command naming a real manager must not match.
        MockLegacyRemotePlasmaVault lv = new MockLegacyRemotePlasmaVault(IERC20(address(usdc)), "No WM", "NWVLT");
        MockWithdrawManager wm = new MockWithdrawManager(address(lv));
        _allowVault(address(lv));
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("dep"), 1, address(lv), 50e6, 0);

        bytes memory req = CrosschainMessages.encodeRequestSharesAction(
            address(wm),
            address(lv),
            10e6,
            type(uint256).max
        );
        Command memory c = Command({
            commandId: keccak256("req"),
            sequence: 2,
            commandConfigEpoch: dispatcher.commandConfigEpoch(),
            action: uint8(BusinessAction.REQUEST_SHARES),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: req
        });
        vm.prank(address(dispatcher));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.WithdrawManagerUnresolved.selector, address(lv)));
        dispatcher.runBusinessSelf(c.commandId, uint8(MsgType.COMMAND), abi.encode(c));

        _command(keccak256("req"), 2, uint8(BusinessAction.REQUEST_SHARES), req);
        assertEq(uint8(dispatcher.commandStatus(keccak256("req"))), uint8(CommandStatus.FAILED), "NACKed");
    }
}
