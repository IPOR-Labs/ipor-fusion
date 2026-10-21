// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {
    StargateCrosschainCommandFuse,
    StargateCrosschainCommandFuseEnterData,
    StargateCrosschainCommandType
} from "../../contracts/fuses/crosschain/stargate/StargateCrosschainCommandFuse.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {BalanceObservation} from "../../contracts/crosschain/interfaces/ICrosschainExecutor.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

/// @title StargateRetryGateTest
/// @notice IL-8600: a REAL Stargate executor/dispatcher pair, driven through the REAL command fuse (the executor's
///         MANAGER is the vault harness). `activeCommandAction` tracks the active command and `RETRY_COMMAND` of a
///         FAILED DEPOSIT is gated like `SEND_COMMAND`.
contract StargateRetryGateTest is StargateTwoSidedBase {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;

    CrosschainVaultHarness internal vault;

    function setUp() public {
        // The executor's MANAGER is immutable: make it the vault harness before the base deploys the executor.
        vault = new CrosschainVaultHarness(address(new MockERC20("Underlying", "UND", 6)));
        manager = address(vault);

        _twoSidedSetUp();
        _bringUpBothSides();

        StargateCrosschainCommandFuse fuse = new StargateCrosschainCommandFuse(MARKET);
        vault.setFuses(address(0), address(0), address(fuse), address(0));
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, address(remoteVault));
        vault.grantSubstrates(MARKET, substrates);
    }

    function _data(StargateCrosschainCommandType t_)
        internal
        view
        returns (StargateCrosschainCommandFuseEnterData memory d)
    {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
    }

    function _depositViaFuse() internal {
        StargateCrosschainCommandFuseEnterData memory d = _data(StargateCrosschainCommandType.SEND_COMMAND);
        d.command = _depositCommand(1e6);
        vault.enterCommand(d);
    }

    function testShouldTrackActiveCommandAction() public {
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), 0, "no active command");

        // Allowlist the vault: a config update is not a business action.
        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        assertTrue(_commandSlotActive(), "config update in flight");
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), 0, "config update has no business action");
        _relayAll();
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), 0, "cleared after ACK");

        _bridgeToDispatcher(1e6);
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(1e6));
        assertTrue(_commandSlotActive(), "deposit in flight");
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), uint8(BusinessAction.DEPOSIT), "DEPOSIT recorded");

        _relayAll(); // dispatcher executes, ACK clears the slot
        assertFalse(_commandSlotActive(), "slot freed by ACK");
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), 0, "cleared after ACK");
    }

    /// @dev The remote vault is a granted substrate but NOT on the dispatcher allowlist: the dispatcher NACKs.
    function _failedDeposit() internal {
        _depositViaFuse();
        _relayAll();
        (bool active,,, CommandStatus status,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(active, "slot still held");
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "precondition: FAILED");
        assertEq(executor.activeCommandAction(REMOTE_CHAIN), uint8(BusinessAction.DEPOSIT), "action kept while FAILED");
    }

    function testShouldGateFuseRetryOfFailedDepositOnNavFailClosed() public {
        // No idle bridged yet: NAV is trivially healthy, so the fuse SEND_COMMAND passes and the dispatcher NACKs.
        _failedDeposit();

        // Bridge idle that has never been attested: the REAL fail-closed NAV (settled balance without an approval).
        _bridgeToDispatcher(1e6);
        StargateCrosschainCommandFuseEnterData memory d = _data(StargateCrosschainCommandType.RETRY_COMMAND);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.NavSettledStale.selector, REMOTE_CHAIN));
        vault.enterCommand(d);

        // NAV healthy again (attested): the retry proceeds and performs exactly one live NAV read.
        _attest(1e6, 1);
        uint256 sent = endpoint.sentCount();
        vm.expectCall(address(executor), abi.encodeWithSelector(executor.getBalance.selector), 1);
        vault.enterCommand(d);
        assertEq(endpoint.sentCount(), sent + 1, "retry message sent");
    }

    /// @notice IL-8625: the fuse's RETRY_COMMAND with a non-zero `command.minExecutionGas` forwards the raise
    ///         (`retryCommandWithBudget`): the RETRY carries it and the send carries the extra `lzReceive` option.
    function testShouldForwardARaisedBudgetThroughTheFuseRetry() public {
        _failedDeposit();
        _bridgeToDispatcher(1e6);
        _attest(1e6, 1);
        StargateCrosschainCommandFuseEnterData memory d = _data(StargateCrosschainCommandType.RETRY_COMMAND);
        d.command.minExecutionGas = 6_000_000;
        vault.enterCommand(d);

        MockLzEndpoint.SentMessage memory m = endpoint.lastSent();
        (, bytes memory data) = CrosschainMessages.decodeEnvelope(m.message);
        assertEq(CrosschainMessages.decodeRetryCommand(data).minExecutionGas, 6_000_000, "the retry carries the raise");
        assertGt(endpoint.lzReceiveGasOf(m.options), commandLaneGas, "and the send funds the extra lzReceive gas");
    }

    function _attest(uint256 settledLD_, uint64 stateVersion_) internal {
        BalanceObservation memory o = BalanceObservation({
            chainId: REMOTE_CHAIN,
            settledBalance: settledLD_,
            stateVersion: stateVersion_,
            remoteBlock: 1,
            remoteTimestamp: uint64(block.timestamp),
            expiry: uint64(block.timestamp + 30 minutes),
            trackedPositionSetHash: bytes32(0)
        });
        vm.prank(proposer);
        executor.proposeBalance(o);
        uint256 proposalId = executor.proposalCount();
        vm.prank(approver);
        executor.approveBalance(proposalId);
    }
}
