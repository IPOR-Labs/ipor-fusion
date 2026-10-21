// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipExecutorCommandLib,
    ReceiptIgnoreReason
} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {
    BusinessAction,
    CcipChainRescue,
    CommandResolution,
    CommandStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CommandStateHarness} from "./CcipExecutorCommandLibTest.t.sol";

contract LateEpochToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipLateReceiptEpochTest
/// @notice IL-8632 (Ackee TP-L-04): a correctly declared `ABANDON_COMMAND(true)` of an UPDATE_VAULTS that
///         succeeded on the dispatcher advances the local command sequence but not `commandConfigEpoch`. The
///         delayed ACK is the only authenticated source of the new epoch; it used to be ignored as "below the
///         mirror", leaving every later command stamped with a stale epoch (the dispatcher NACKs
///         `InvalidConfigEpoch` for all of them). The ACK for exactly `nextCommandSequence - 1` now refreshes
///         the epoch mirror whether or not a later command owns the slot.
contract CcipLateReceiptEpochTest is Test {
    uint64 internal constant BOOT_EPOCH = 1; // `initializeRoute` starts the mirror at 1
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    LateEpochToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    /// @dev Mirrors the executor's private command nonce. `activeCommand` cannot be read back after a
    ///      send whose receipt was delivered inside the same call (the mock router is synchronous), so
    ///      command ids are recomputed the way `CcipExecutorCommandLib.build` derives them.
    uint256 internal commandNonce;

    function setUp() public {
        router = new MockCcipRouter();
        token = new LateEpochToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
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
            18,
            block.chainid,
            back,
            ADMIN,
            GUARDIAN,
            RESCUE_DELAY
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
        return CcipCrosschainExecutor.SafetyConfig({
            rescueAdmin: ADMIN,
            rescueGuardian: GUARDIAN,
            balanceProposer: address(this),
            balanceApprover: APPROVER,
            rescueDelay: RESCUE_DELAY,
            balanceStalenessMax: 7 days,
            bigChangeBps: 2_000,
            minUpdateInterval: 1 hours,
            transferStalenessMax: 1 days
        });
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Make every dispatcher -> executor response undeliverable. The dispatcher catches the send
    ///      failure and leaves the response at the head of its FIFO queue, which is how a fee ceiling or
    ///      a receiver failure looks in production.
    function _holdResponses() internal {
        router.setFailSend(address(dispatcher), true);
    }

    /// @dev Repair delivery and drain the queue through the permissionless `flushResponse`.
    function _releaseResponses() internal {
        router.setFailSend(address(dispatcher), false);
        while (dispatcher.responseQueueHead() != 0) {
            dispatcher.flushResponse();
        }
    }

    function _abandonArg(bool consumed_) internal pure returns (uint256) {
        return consumed_ ? 1 : 0;
    }

    function _abandon(bool consumed_) internal {
        vm.prank(ADMIN);
        uint256 rescueId =
            executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, _abandonArg(consumed_));
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, _abandonArg(consumed_));
    }

    function _attestBalance(uint256 balance_) internal {
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
        vm.prank(APPROVER);
        executor.approveBalance(proposalId);
    }

    function _fundRemoteIdle(uint256 amount_) internal {
        token.mint(address(executor), amount_);
        // `sendAssetToDispatcher` derives its operation id from the SAME private nonce counter that
        // command ids use, so the mirror has to follow it.
        ++commandNonce;
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    /// @dev The id `CcipExecutorCommandLib.build` will stamp on the next command this executor builds in
    ///      this block (the high 64 bits carry the command's deadline, IL-8255).
    function _nextCommandId() internal returns (bytes32) {
        return CrosschainMessages.stampCommandId(
            keccak256(abi.encode(address(executor), REMOTE_CHAIN, "CCIP_COMMAND", ++commandNonce))
        );
    }

    function _deployAndAllowVault() internal returns (MockRemoteVault vault) {
        vault = new MockRemoteVault(token, "Remote", "rUSDC");
        _allowVault(address(vault));
    }

    function _allowVault(address vault_) internal returns (bytes32 commandId) {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        commandId = _nextCommandId();
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
    }

    function _sendDeposit(MockRemoteVault vault_, uint256 amount_) internal returns (bytes32 commandId) {
        commandId = _nextCommandId();
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vault_), amount_, 0)
            }),
            0,
            address(0),
            2_000_000
        );
    }

    function _updateVaultsHeld() internal returns (bytes32 commandId, MockRemoteVault vault) {
        _holdResponses();
        vault = new MockRemoteVault(token, "Remote2", "rUSDC2");
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        commandId = _nextCommandId();
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "dispatcher ran it");
    }

    function testShouldAdoptTheEpochOfTheReceiptOfACorrectlyAbandonedUpdateVaults() public {
        _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        (bytes32 commandId, MockRemoteVault vault) = _updateVaultsHeld();
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);

        _abandon(true);
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), "sequence followed");
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore, "abandon cannot carry the epoch");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore + 1, "dispatcher advanced its epoch");

        router.setFailSend(address(dispatcher), false);
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.LateReceiptEpochAdopted(REMOTE_CHAIN, sequence, epochBefore, epochBefore + 1);
        vm.expectEmit(false, false, false, false, address(executor)); // CommandAcknowledged (topic only)
        emit CcipExecutorCommandLib.CommandAcknowledged(0, bytes32(0), 0, 0, 0, 0, 0);
        dispatcher.flushResponse();
        _releaseResponses();

        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore + 1, "epoch mirror refreshed");
        _assertMirrorsMatchDispatcher("both mirrors match the dispatcher");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot free");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "abandon verdict kept");

        // Consumer: every command is stamped with the mirrored epoch and the dispatcher NACKs a stale one.
        bytes32 depositId = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(depositId)), uint8(CommandStatus.SUCCEEDED), "next command accepted");
    }

    function testShouldKeepTheNextCommandStaleWithoutAdoption() public {
        // Documents the failure the fix removes: with the receipt still queued the epoch is stale and the
        // dispatcher rejects the next command.
        _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        (, MockRemoteVault vault) = _updateVaultsHeld();
        _abandon(true);
        bytes32 depositId = _sendDeposit(vault, 10e18);
        assertTrue(
            dispatcher.commandStatus(depositId) != CommandStatus.SUCCEEDED, "stale epoch is not accepted"
        );
    }

    function testShouldAdoptTheEpochWhileANewCommandOwnsTheSlot() public {
        _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        (, MockRemoteVault vault) = _updateVaultsHeld();
        _abandon(true);
        bytes32 depositId = _sendDeposit(vault, 10e18); // stale epoch, stays outstanding
        assertEq(executor.activeCommand(REMOTE_CHAIN), depositId, "slot busy");
        uint64 sequence = executor.nextCommandSequence(REMOTE_CHAIN);

        router.setFailSend(address(dispatcher), false);
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.LateReceiptEpochAdopted(REMOTE_CHAIN, sequence - 1, epochBefore, epochBefore + 1);
        dispatcher.flushResponse(); // the late ACK of the abandoned UPDATE_VAULTS
        _releaseResponses(); // the stale deposit's NACK

        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore + 1, "busy slot: epoch adopted all the same");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequence, "sequence untouched");
        assertEq(executor.activeCommand(REMOTE_CHAIN), depositId, "replacement untouched");
        assertEq(uint8(executor.commandStatus(depositId)), uint8(CommandStatus.FAILED), "stale replacement NACKed");

        // The replacement still needs its own resolution; its CANCELLED receipt only frees the slot now.
        executor.cancelCommand(REMOTE_CHAIN, depositId, 0, address(0), 2_000_000);
        _releaseResponses();
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot free after cancel");
        _assertMirrorsMatchDispatcher("mirrors match after the cancel");
        bytes32 nextId = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(nextId)), uint8(CommandStatus.SUCCEEDED), "lane usable again");
    }

    function testShouldKeepTheAdoptedEpochWhenTheStaleCommandIsCancelledPastItsDeadline() public {
        _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        uint64 epochBefore = executor.commandConfigEpoch(REMOTE_CHAIN);
        (, MockRemoteVault vault) = _updateVaultsHeld();
        _abandon(true);
        bytes32 depositId = _sendDeposit(vault, 10e18); // stale epoch
        _releaseResponses(); // late ACK adopted while the slot is busy, then the deposit's NACK
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), epochBefore + 1, "epoch adopted");

        // Cancelled only after its deadline: the dispatcher answers EXPIRED, which frees the slot without
        // touching the epoch. The epoch is already right, so no second round is needed.
        vm.warp(CrosschainMessages.commandDeadline(depositId) + 1);
        executor.cancelCommand(REMOTE_CHAIN, depositId, 0, address(0), 2_000_000);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "EXPIRED freed the slot");
        _assertMirrorsMatchDispatcher("mirrors match after EXPIRED");
        bytes32 nextId = _sendDeposit(vault, 10e18);
        assertEq(uint8(dispatcher.commandStatus(nextId)), uint8(CommandStatus.SUCCEEDED), "lane usable again");
    }

    // ---------------------------------------------------------------------
    // Branch table at library level
    // ---------------------------------------------------------------------

    function _lib() internal returns (CommandStateHarness h, bytes32 id, uint64 seq) {
        h = new CommandStateHarness();
        h.initializeRoute(REMOTE_CHAIN);
        (id, seq) = h.build(REMOTE_CHAIN, true, 1);
    }

    function _abandonConsumed(CommandStateHarness h) internal {
        vm.warp(
            CrosschainMessages.commandDeadline(h.activeCommand(REMOTE_CHAIN))
                + CrosschainConstants.COMMAND_EXPIRY_MARGIN + 1
        );
        h.abandon(REMOTE_CHAIN, true);
    }

    function testShouldAdoptOnlyTheEpochAtNextSequenceMinusOne() public {
        (CommandStateHarness h, bytes32 id, uint64 seq) = _lib();
        uint64 epoch = h.commandConfigEpoch(REMOTE_CHAIN);
        _abandonConsumed(h);

        vm.expectEmit(false, false, false, true, address(h));
        emit CcipExecutorCommandLib.LateReceiptEpochAdopted(REMOTE_CHAIN, seq, epoch, epoch + 1);
        ReceiptIgnoreReason reason = h.acknowledge(REMOTE_CHAIN, id, seq, CommandResolution.SUCCEEDED, epoch + 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "adopted");
        assertEq(h.commandConfigEpoch(REMOTE_CHAIN), epoch + 1, "epoch refreshed");
        assertEq(h.nextCommandSequence(REMOTE_CHAIN), seq + 1, "sequence untouched");
        assertEq(h.activeCommand(REMOTE_CHAIN), bytes32(0), "slot free");

        // A transport duplicate carries no newer epoch and is a no-op.
        reason = h.acknowledge(REMOTE_CHAIN, id, seq, CommandResolution.SUCCEEDED, epoch + 1);
        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "duplicate ignored");
    }

    function testShouldIgnoreAReceiptOlderThanNextSequenceMinusOne() public {
        (CommandStateHarness h, bytes32 first, uint64 firstSeq) = _lib();
        _abandonConsumed(h);
        h.build(REMOTE_CHAIN, false, 2);
        _abandonConsumed(h); // next = firstSeq + 2

        ReceiptIgnoreReason reason = h.acknowledge(REMOTE_CHAIN, first, firstSeq, CommandResolution.SUCCEEDED, 5);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "older receipt ignored");
        assertEq(h.commandConfigEpoch(REMOTE_CHAIN), BOOT_EPOCH, "epoch untouched");
        assertEq(h.nextCommandSequence(REMOTE_CHAIN), firstSeq + 2, "sequence untouched");
    }

    function testShouldIgnoreANonAdvancingEpochOnTheLateReceipt() public {
        (CommandStateHarness h, bytes32 id, uint64 seq) = _lib();
        _abandonConsumed(h);

        ReceiptIgnoreReason reason = h.acknowledge(REMOTE_CHAIN, id, seq, CommandResolution.SUCCEEDED, BOOT_EPOCH);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.ALREADY_RESOLVED), "same epoch is no news");
        assertEq(h.commandConfigEpoch(REMOTE_CHAIN), BOOT_EPOCH, "epoch untouched");
    }

    function testShouldNotAdoptAnEpochFromALateNack() public {
        (CommandStateHarness h, bytes32 id, uint64 seq) = _lib();
        _abandonConsumed(h);

        ReceiptIgnoreReason reason = h.fail(REMOTE_CHAIN, id, seq);

        assertTrue(reason != ReceiptIgnoreReason.NONE, "a NACK of the abandoned command is not applied");
        assertEq(h.commandConfigEpoch(REMOTE_CHAIN), BOOT_EPOCH, "no epoch adopted");
        assertEq(h.nextCommandSequence(REMOTE_CHAIN), seq + 1, "sequence untouched");
    }

    function testShouldAdoptTheEpochWhileTheSlotIsBusyAtLibraryLevel() public {
        (CommandStateHarness h, bytes32 id, uint64 seq) = _lib();
        _abandonConsumed(h);
        (bytes32 replacement,) = h.build(REMOTE_CHAIN, false, 2);

        ReceiptIgnoreReason reason = h.acknowledge(REMOTE_CHAIN, id, seq, CommandResolution.SUCCEEDED, BOOT_EPOCH + 1);

        assertEq(uint8(reason), uint8(ReceiptIgnoreReason.NONE), "busy slot: epoch adopted");
        assertEq(h.commandConfigEpoch(REMOTE_CHAIN), BOOT_EPOCH + 1, "epoch refreshed");
        assertEq(h.nextCommandSequence(REMOTE_CHAIN), seq + 1, "sequence untouched");
        assertEq(h.activeCommand(REMOTE_CHAIN), replacement, "replacement untouched");
        assertEq(uint8(h.status(replacement)), uint8(CommandStatus.PENDING), "replacement status untouched");
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }
}
