// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {
    BusinessAction,
    CcipChainRescue,
    CommandStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";

contract ExpiryToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipCommandExpiryTest
/// @notice IL-8255 (R-05), CCIP half, end to end against a REAL dispatcher. A COMMAND / UPDATE_VAULTS that
///         reverted on the dispatcher stays FAILED on the OffRamp and anyone may execute it manually, so it
///         used to outlive an `ABANDON_COMMAND` rescue: once the lane reached its sequence it ran the abandoned
///         business action and its ACK superseded the live replacement on the executor. There is no
///         receiver-side way to invalidate such a message on CCIP, so the command TTL is the only exit.
/// @dev `MockCcipRouter` holds a token-less message sent while `autoDeliver` is off and executes it on
///      `deliverHeld`, which models a message still in flight or FAILED on the OffRamp. Receipts travel
///      back synchronously as usual.
contract CcipCommandExpiryTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;

    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    MockCcipRouter internal router;
    ExpiryToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    address internal factory;

    event CommandFailed(bytes32 commandId, uint64 sequence);

    function setUp() public {
        router = new MockCcipRouter();
        token = new ExpiryToken();
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

    function _abandon(bool consumed_) internal {
        uint256 arg = consumed_ ? 1 : 0;
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, arg);
    }

    function _realign(uint64 epoch_, uint64 sequence_) internal {
        uint256 arg = (uint256(executor.commandConfigEpoch(REMOTE_CHAIN)) << 192)
            | (uint256(executor.nextCommandSequence(REMOTE_CHAIN)) << 128) | (uint256(epoch_) << 64) | uint256(sequence_);
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.REALIGN_COMMAND_LANE, REMOTE_CHAIN, arg);
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
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
        _attestBalance(dispatcher.accountedBalance());
    }

    function _allowVaults(address[] memory vaults_) internal returns (bytes32 commandId) {
        executor.updateVaults(REMOTE_CHAIN, vaults_, true, true, 0, address(0), 2_000_000);
        commandId = executor.activeCommand(REMOTE_CHAIN);
    }

    function _oneVault(address vault_) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault_;
    }

    /// @dev Send a DEPOSIT whose message is held rather than delivered. Returns its id and held index.
    function _holdDeposit(MockRemoteVault vault_, uint256 amount_) internal returns (bytes32 commandId, uint256 held) {
        router.setAutoDeliver(false);
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
        router.setAutoDeliver(true);
        commandId = executor.activeCommand(REMOTE_CHAIN);
        held = router.heldCount() - 1;
    }

    function _deployAndAllowVault() internal returns (MockRemoteVault vault) {
        vault = new MockRemoteVault(token, "Remote", "rUSDC");
        _allowVaults(_oneVault(address(vault)));
    }

    function _assertMirrorsMatchDispatcher(string memory label_) internal view {
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), dispatcher.nextCommandSequence(), label_);
        assertEq(executor.commandConfigEpoch(REMOTE_CHAIN), dispatcher.commandConfigEpoch(), label_);
    }

    // ---------------------------------------------------------------------
    // E1 — the FAILED message at the sequence its replacement reuses
    // ---------------------------------------------------------------------

    /// @notice The finding's main path without any wrong declaration: a DEPOSIT never ran, the operator
    ///         abandons it — correctly — as UNUSED and sends a replacement at the same sequence, and the old
    ///         message is then executed manually first. It must NACK: no capital moves, the sequence stays,
    ///         and the replacement is resolved by its own receipt instead of being superseded.
    function testShouldNackARetainedCommandInsteadOfSupersedingItsReplacement() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        (bytes32 abandoned, uint256 abandonedHeld) = _holdDeposit(vault, 50e18);
        _abandon(false);
        uint64 sequence = dispatcher.nextCommandSequence();
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), sequence, "mirror parked on the abandoned sequence");

        (bytes32 replacement, uint256 replacementHeld) = _holdDeposit(vault, 10e18);
        uint256 idleBefore = dispatcher.trackedIdle();

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(abandoned, sequence);
        router.deliverHeld(abandonedHeld);

        assertEq(uint8(dispatcher.commandStatus(abandoned)), uint8(CommandStatus.FAILED), "expired work NACKed");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the sequence did not move");
        assertEq(dispatcher.trackedIdle(), idleBefore, "the abandoned 50e18 deposit did not run");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "no position opened by the abandoned intent");
        assertEq(executor.activeCommand(REMOTE_CHAIN), replacement, "the replacement still owns the slot");

        router.deliverHeld(replacementHeld);

        assertEq(uint8(dispatcher.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "replacement ran");
        assertEq(dispatcher.trackedIdle(), idleBefore - 10e18, "only the replacement's deposit moved capital");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "resolved by its own receipt");
        assertEq(uint8(executor.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "recorded as run");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E2 — the FAILED message ahead of the lane (the ticket's scenario)
    // ---------------------------------------------------------------------

    /// @notice A wrong CONSUMED declaration puts the mirror ahead, so the next command fails with
    ///         `InvalidSequence` and stays manually executable. After ABANDON + REALIGN down, a command at the
    ///         lower sequence brings the lane up to it; executing it then must NACK instead of running the
    ///         abandoned deposit and superseding the live command at that sequence.
    function testShouldNackACommandRetainedAheadOfTheLaneAfterARealignDown() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);

        _holdDeposit(vault, 10e18); // never delivered
        _abandon(true); // the wrong declaration
        uint64 n = dispatcher.nextCommandSequence();

        (bytes32 ahead, uint256 aheadHeld) = _holdDeposit(vault, 50e18); // stamped n + 1
        vm.expectRevert(abi.encodeWithSelector(CcipCrosschainDispatcher.InvalidSequence.selector, n, n + 1));
        router.deliverHeld(aheadHeld);

        _abandon(false);
        _realign(dispatcher.commandConfigEpoch(), n);

        (bytes32 atN, uint256 atNHeld) = _holdDeposit(vault, 5e18);
        router.deliverHeld(atNHeld);
        assertEq(uint8(dispatcher.commandStatus(atN)), uint8(CommandStatus.SUCCEEDED), "command at n ran");
        assertEq(dispatcher.nextCommandSequence(), n + 1, "the lane reached the retained message's sequence");

        (bytes32 live, uint256 liveHeld) = _holdDeposit(vault, 7e18);
        uint256 idleBefore = dispatcher.trackedIdle();

        router.deliverHeld(aheadHeld);

        assertEq(uint8(dispatcher.commandStatus(ahead)), uint8(CommandStatus.FAILED), "expired work NACKed");
        assertEq(dispatcher.trackedIdle(), idleBefore, "the abandoned 50e18 deposit did not run");
        assertEq(dispatcher.nextCommandSequence(), n + 1, "the sequence did not move");
        assertEq(executor.activeCommand(REMOTE_CHAIN), live, "the live command still owns the slot");

        router.deliverHeld(liveHeld);
        assertEq(uint8(dispatcher.commandStatus(live)), uint8(CommandStatus.SUCCEEDED), "the live command ran");
        assertEq(dispatcher.trackedIdle(), idleBefore - 7e18, "and only it moved capital");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E3 — a FAILED UPDATE_VAULTS
    // ---------------------------------------------------------------------

    /// @notice A config update outliving an abandon must not rewrite the allowlist either.
    function testShouldNackARetainedUpdateVaultsInsteadOfApplyingTheAbandonedAllowlist() public {
        MockRemoteVault abandonedVault = new MockRemoteVault(token, "Abandoned", "aUSDC");
        MockRemoteVault chosenVault = new MockRemoteVault(token, "Chosen", "cUSDC");

        router.setAutoDeliver(false);
        bytes32 abandoned = _allowVaults(_oneVault(address(abandonedVault)));
        router.setAutoDeliver(true);
        uint256 abandonedHeld = router.heldCount() - 1;

        _abandon(false);

        router.setAutoDeliver(false);
        bytes32 replacement = _allowVaults(_oneVault(address(chosenVault)));
        router.setAutoDeliver(true);
        uint256 replacementHeld = router.heldCount() - 1;
        uint64 epochBefore = dispatcher.commandConfigEpoch();

        router.deliverHeld(abandonedHeld);

        assertEq(uint8(dispatcher.commandStatus(abandoned)), uint8(CommandStatus.FAILED), "expired update NACKed");
        assertFalse(dispatcher.isAllowedVault(address(abandonedVault)), "the abandoned allowlist was not applied");
        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "the epoch did not move");

        router.deliverHeld(replacementHeld);
        assertEq(uint8(dispatcher.commandStatus(replacement)), uint8(CommandStatus.SUCCEEDED), "replacement ran");
        assertTrue(dispatcher.isAllowedVault(address(chosenVault)), "the replacement's allowlist holds");
        assertFalse(dispatcher.isAllowedVault(address(abandonedVault)), "and only it");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "resolved by its own receipt");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E4 — the TTL on the live lane
    // ---------------------------------------------------------------------

    /// @notice The deadline itself is still inside the window (`block.timestamp > deadline` expires).
    function testShouldExecuteACommandDeliveredExactlyAtItsDeadline() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        (bytes32 commandId, uint256 held) = _holdDeposit(vault, 10e18);

        vm.warp(CrosschainMessages.commandDeadline(commandId));
        router.deliverHeld(held);

        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ran at the deadline");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    /// @notice A live command delivered after its deadline is NACKed like any business failure; a retry
    ///         cannot revive it (the executor refuses to send one), and the manager's CANCEL is answered with an `EXPIRED` receipt that frees the lane
    ///         without consuming the sequence (IL-8594), so no abandon is needed.
    function testShouldNackALateCommandAndLetTheOperatorCancelIt() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        (bytes32 commandId, uint256 held) = _holdDeposit(vault, 10e18);
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 sequence = dispatcher.nextCommandSequence();

        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        router.deliverHeld(held);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "late command NACKed");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "the executor saw the NACK");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the sequence did not move");

        // IL-8625: a retry cannot revive it either, and the executor refuses to send one (it could only NACK again).
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandExpired.selector, commandId));
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 2_000_000);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "still FAILED");
        assertEq(dispatcher.trackedIdle(), idleBefore, "nothing ran");

        // IL-8594: an expired command's CANCEL consumes no sequence and is answered EXPIRED; the executor frees the
        // slot for the FAILED command it names and keeps its sequence mirror, so no abandon is needed.
        vm.expectEmit(false, false, false, true, address(executor));
        emit CcipExecutorCommandLib.CommandExpiryReleased(REMOTE_CHAIN, commandId, sequence);
        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 2_000_000);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "closed");
        assertEq(dispatcher.nextCommandSequence(), sequence, "the expired cancel did not move the lane");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot freed by the EXPIRED receipt");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "executor closed it");
        _assertMirrorsMatchDispatcher("lane in lockstep");
    }

    // ---------------------------------------------------------------------
    // E5 — the abandon waits for the deadline on both chains
    // ---------------------------------------------------------------------

    /// @notice The chain rescue is refused up to and including `deadline + COMMAND_EXPIRY_MARGIN` and
    ///         accepted one second later. It is scheduled before the command exists so the timelock alone
    ///         cannot carry the execution past the deadline.
    function testShouldRejectAnAbandonUntilTheCommandExpiredOnBothChains() public {
        MockRemoteVault vault = _deployAndAllowVault();
        _fundRemoteIdle(100e18);
        vm.prank(ADMIN);
        uint256 rescueId = executor.scheduleChainRescue(CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, 0);
        vm.warp(block.timestamp + RESCUE_DELAY);

        (bytes32 commandId,) = _holdDeposit(vault, 10e18);
        uint256 abandonableAt =
            CrosschainMessages.commandDeadline(commandId) + CrosschainConstants.COMMAND_EXPIRY_MARGIN;
        bytes memory notExpired =
            abi.encodeWithSelector(CcipExecutorCommandLib.CommandNotExpired.selector, commandId, abandonableAt);

        vm.prank(ADMIN);
        vm.expectRevert(notExpired);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, 0);

        vm.warp(abandonableAt);
        vm.prank(ADMIN);
        vm.expectRevert(notExpired);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, 0);
        assertEq(executor.activeCommand(REMOTE_CHAIN), commandId, "the slot is still held");

        vm.warp(abandonableAt + 1);
        vm.prank(ADMIN);
        executor.executeChainRescue(rescueId, CcipChainRescue.ABANDON_COMMAND, REMOTE_CHAIN, 0);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "abandoned once expired on both chains");
    }
}
