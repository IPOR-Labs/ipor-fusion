// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {StargateExecutorCommandLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorCommandLib.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";

import {CrosschainMessages, Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";

import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateVaultsUpdateObservabilityTest
/// @notice IL-8470 (B-10): the dispatcher's `VaultsUpdated` carries only a count (no EIP-170 room to add the
///         list), so the executor publishes the full list in `VaultsUpdateRequested`, joinable by epoch.
contract StargateVaultsUpdateObservabilityTest is StargateTwoSidedBase {
    function setUp() public {
        _twoSidedSetUp();
        _bringUpBothSides();
    }

    function testShouldPublishAllowlistOnExecutorAndJoinDispatcherVaultsUpdatedByEpoch() public {
        MockRemoteVault second = new MockRemoteVault(IERC20(address(usdc)), "Remote Vault 2", "RVLT2");
        address[] memory vaults = new address[](2);
        vaults[0] = address(remoteVault);
        vaults[1] = address(second);

        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        Vm.Log[] memory sendLogs = vm.getRecordedLogs();

        (, , , , bytes32 commandId, uint64 sequence, uint64 newEpoch) = executor.activeCommand(REMOTE_CHAIN);

        uint256 found;
        for (uint256 i; i < sendLogs.length; ++i) {
            if (
                sendLogs[i].emitter == address(executor) &&
                sendLogs[i].topics[0] == StargateExecutorCommandLib.VaultsUpdateRequested.selector
            ) {
                ++found;
                (uint256 dst, bytes32 id, uint64 seq, uint64 epoch, address[] memory list) = abi.decode(
                    sendLogs[i].data,
                    (uint256, bytes32, uint64, uint64, address[])
                );
                assertEq(dst, REMOTE_CHAIN, "dstChainId");
                assertEq(id, commandId, "commandId");
                assertEq(seq, sequence, "sequence");
                assertEq(epoch, newEpoch, "newConfigEpoch");
                assertEq(list.length, 2, "list length");
                assertEq(list[0], vaults[0], "list[0]");
                assertEq(list[1], vaults[1], "list[1]");
            }
        }
        assertEq(found, 1, "exactly one VaultsUpdateRequested from the executor");

        vm.recordLogs();
        _relayAt(_lastSentIndex()); // executor -> dispatcher : UPDATE_VAULTS
        Vm.Log[] memory applyLogs = vm.getRecordedLogs();

        uint256 applied;
        for (uint256 i; i < applyLogs.length; ++i) {
            if (
                applyLogs[i].emitter == address(dispatcher) &&
                applyLogs[i].topics[0] == StargateCrosschainDispatcher.VaultsUpdated.selector
            ) {
                ++applied;
                (uint64 cfgEpoch, , uint256 count) = abi.decode(applyLogs[i].data, (uint64, uint64, uint256));
                assertEq(cfgEpoch, newEpoch, "dispatcher epoch joins the executor event");
                assertEq(count, 2, "count");
            }
        }
        assertEq(applied, 1, "exactly one VaultsUpdated from the dispatcher");

        address[] memory allowed = dispatcher.getAllowedVaults();
        assertEq(allowed.length, 2, "allowed length");
        assertEq(allowed[0], vaults[0], "allowed[0]");
        assertEq(allowed[1], vaults[1], "allowed[1]");
    }

    /// @notice IL-8471 (B-11): `CommandSent.action` must tell a REDEEM_FROM_REQUEST business command (4) apart
    ///         from an allowlist update (0xFF, formerly `MsgType.UPDATE_VAULTS` == 4).
    function testShouldDistinguishRedeemFromRequestAndAllowlistUpdateInCommandSentAction() public {
        Command memory redeem = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.REDEEM_FROM_REQUEST),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeRedeemFromRequestAction(
                address(0xBEEF),
                address(remoteVault),
                1,
                0,
                address(dispatcher)
            )
        });

        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        Vm.Log[] memory updateLogs = vm.getRecordedLogs();
        (, , , , bytes32 updateId, , ) = executor.activeCommand(REMOTE_CHAIN);

        // One command lane slot per chain: deliver the command and its receipt so the slot frees.
        _relayAll();
        assertFalse(_commandSlotActive(), "slot freed after the receipt");

        vm.recordLogs();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, redeem);
        Vm.Log[] memory redeemLogs = vm.getRecordedLogs();
        (, , , , bytes32 redeemId, , ) = executor.activeCommand(REMOTE_CHAIN);

        (bytes32 sentRedeemId, uint8 redeemAction) = _singleCommandSent(redeemLogs);
        assertEq(sentRedeemId, redeemId, "redeem commandId");
        assertEq(redeemAction, uint8(BusinessAction.REDEEM_FROM_REQUEST), "redeem action == 4");

        (bytes32 sentUpdateId, uint8 updateAction) = _singleCommandSent(updateLogs);
        assertEq(sentUpdateId, updateId, "update commandId");
        assertEq(updateAction, type(uint8).max, "allowlist update action == 255");
        assertTrue(updateAction != redeemAction, "kinds are distinguishable");

        uint256 requested;
        for (uint256 i; i < updateLogs.length; ++i) {
            if (
                updateLogs[i].emitter == address(executor) &&
                updateLogs[i].topics[0] == StargateExecutorCommandLib.VaultsUpdateRequested.selector
            ) {
                ++requested;
                (, bytes32 id, , , ) = abi.decode(updateLogs[i].data, (uint256, bytes32, uint64, uint64, address[]));
                assertEq(id, sentUpdateId, "VaultsUpdateRequested.commandId joins CommandSent.commandId");
            }
        }
        assertEq(requested, 1, "one VaultsUpdateRequested");
    }

    function _singleCommandSent(Vm.Log[] memory logs_) private view returns (bytes32 commandId, uint8 action) {
        uint256 found;
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(executor) &&
                logs_[i].topics[0] == StargateCrosschainExecutor.CommandSent.selector
            ) {
                ++found;
                (, commandId, , action) = abi.decode(logs_[i].data, (uint256, bytes32, uint64, uint8));
            }
        }
        assertEq(found, 1, "exactly one CommandSent from the executor");
    }
}
