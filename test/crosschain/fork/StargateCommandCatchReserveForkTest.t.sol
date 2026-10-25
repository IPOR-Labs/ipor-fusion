// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {Vm} from "forge-std/Vm.sol";

import {StargateForkBase} from "./StargateForkBase.sol";
import {ColdGas} from "../ColdGas.sol";
import {MockGasBurnVault} from "../mocks/MockGasBurnVault.sol";
import {
    BusinessAction,
    CommandStatus,
    CrosschainConstants,
    MsgType
} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CommandNack, CrosschainMessages} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";

/// @title StargateCommandCatchReserveForkTest
/// @notice IL-9179 (Codex audit finding stargate-disp C-004): `COMMAND_CATCH_RESERVE_GAS` (400,000) was sized on a mock
///         endpoint. This suite proves it on the REAL EndpointV2: a callee that burns everything it was forwarded and
///         then reverts with a selector (`MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR`, tracked by the
///         dispatcher through a real UPDATE_VAULTS) still ends in FAILED plus exactly one NACK, when the delivery
///         carries the smallest gas `G` that gets past the budget check.
/// @dev What it asserts. (1) `G` is found by bisection on the real endpoint, not by a formula. (2) At `G - 1` the delivery
///      reverts `InsufficientGasForCommand(have, need)` with `need` = the stamped budget, nothing is written and the
///      packet stays retryable. (3) At `G` the business call runs out of gas in the capped self-call, the catch records
///      FAILED, the NACK goes out through the real endpoint (decoded: `CommandNack{commandId, sequence}`), the lane
///      sequence and `trackedIdle` are unchanged, and the gas left over once the delivery returns (the catch headroom)
///      stays above `MIN_HEADROOM`.
///      Cold measurement (as `StargatePreCheckForkTest`, forge 1.8.5 semantics): `foundry.toml` has `isolate = false`, so
///      a test is ONE transaction and the probes would warm the endpoint, the fee quote contracts and the storage.
///      Before every trial `vm.cool` re-cools every slot of every account the delivery touches (recorded from one run).
///      Account warmth cannot be reset, so `G` is the threshold with cold slots and warm accounts. A fully cold delivery
///      needs at most `G + ColdGas._coldAccountPenalty` (2,500 per touched account, a deliberate over-count), and the
///      test asserts that bound is at most `laneGas`, the gas the executor registers for this command lane. The same
///      penalty is subtracted from the headroom. The catch frame keeps `COMMAND_CATCH_RESERVE_GAS` whatever `G` is; a
///      cold delivery at the warm `G` fails safe with `InsufficientGasForCommand` and the packet stays retryable. No
///      `vm.warp` / `vm.roll`: the fork backend is shared with the other Stargate suites.
///      Measured (forge 1.8.5, Arbitrum block 510,000,000, lane gas 4,000,000, cold slots, warm accounts, 22 touched
///      accounts): stamped budget 3,173,500; `G` = 3,746,605 (so the hop to the OApp and the pre-call work cost 573,105
///      above the budget); at `G - 1` the dispatcher sees gasleft 3,173,478 (22 below the budget); the whole delivery
///      at `G` uses 3,421,730, leaving 324,876 unspent after the NACK is sent (269,876 after the 55,000 cold account
///      over-count). Cold upper bound `G` + 55,000 = 3,801,605, which leaves a margin of 198,395 under the 4,000,000
///      lane gas. The catch frame starts with the 400,000 reserve plus what the self-call hands back, so the NACK path
///      itself needs roughly 400,000 - 324,876 + the hand-back, comfortably inside the reserve: the constant holds on
///      the real endpoint.
contract StargateCommandCatchReserveForkTest is StargateForkBase, ColdGas {
    uint256 internal constant SEND_AMOUNT = 1_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 400e6;
    /// @dev Required headroom left after the cold-adjusted catch path at `G`.
    uint256 internal constant MIN_HEADROOM = 50_000;

    MockGasBurnVault internal burnVault;

    struct Case {
        Packet packet;
        Origin origin;
        bytes32 commandId;
        uint64 sequence;
        uint256 budget;
        address[] touched;
        uint256 snapshot;
    }

    /// @dev Bring-up, a burn-all vault tracked through a real UPDATE_VAULTS, real USDC bridged in, then the DEPOSIT
    ///      command is built and its packet captured (not delivered). Ends on the Arbitrum fork, packet verified.
    function _prepare() internal returns (Case memory c) {
        _createForks();
        _deployApps();
        _bringUp();

        vm.selectFork(arbitrumFork);
        burnVault = new MockGasBurnVault(IERC20(ARBITRUM_USDC));
        burnVault.setMode(MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR);

        _bridgeIn(SEND_AMOUNT);

        address[] memory vaults = new address[](1);
        vaults[0] = address(burnVault);
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(ARBITRUM_CHAIN_ID, vaults);
        Packet memory update = _takePacket(APP);
        vm.selectFork(arbitrumFork);
        _deliver(update, laneGas);
        Packet memory ack = _takePacket(APP);
        vm.selectFork(ethereumFork);
        _deliver(ack, DISPATCHER_RECEIVE_GAS);

        vm.recordLogs();
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            ARBITRUM_CHAIN_ID,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(burnVault), DEPOSIT_AMOUNT, 0)
            })
        );
        c.packet = _takePacket(APP);
        (MsgType t, bytes memory data) = CrosschainMessages.decodeEnvelope(c.packet.message);
        assertEq(uint8(t), uint8(MsgType.COMMAND), "a COMMAND packet");
        Command memory cmd = CrosschainMessages.decodeCommand(data);
        c.commandId = cmd.commandId;
        c.sequence = cmd.sequence;
        c.budget = cmd.minExecutionGas;

        vm.selectFork(arbitrumFork);
        c.origin = _verify(c.packet);
        c.snapshot = vm.snapshotState();
        // The accounts one generous delivery touches; reverted afterwards so the state is untouched.
        _beginRecording();
        (bool ok, , ) = _call(c.origin, c.packet, laneGas);
        c.touched = _endRecording();
        assertTrue(ok, "the delivery at the lane gas succeeds");
        vm.revertToState(c.snapshot);
    }

    function _bridgeIn(uint256 amount_) internal {
        vm.selectFork(ethereumFork);
        deal(ETHEREUM_USDC, APP, amount_);
        (, , OFTReceipt memory receipt) = IStargate(ETHEREUM_STARGATE_USDC).quoteOFT(
            SendParam({
                dstEid: ARBITRUM_EID,
                to: bytes32(uint256(uint160(APP))),
                amountLD: amount_,
                minAmountLD: 0,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
        );
        vm.recordLogs();
        vm.prank(manager);
        executor.sendAssetToDispatcher(ARBITRUM_CHAIN_ID, amount_, receipt.amountReceivedLD, _assetSendOptions());
        Packet memory token = _takeTokenPacket();
        vm.selectFork(arbitrumFork);
        _deliverTokenAndCompose(token, ASSET_SEND_RECEIVE_GAS, ASSET_SEND_COMPOSE_GAS);
        Packet memory settled = _takePacket(APP);
        vm.selectFork(ethereumFork);
        _deliver(settled, DISPATCHER_RECEIVE_GAS);
        vm.selectFork(arbitrumFork);
    }

    /// @dev `endpoint.lzReceive` with exactly `gas_`, keeping the revert data.
    function _call(
        Origin memory origin_,
        Packet memory packet_,
        uint256 gas_
    ) internal returns (bool ok, bytes memory ret, uint256 used) {
        bytes memory callData = abi.encodeCall(
            ENDPOINT.lzReceive,
            (origin_, packet_.receiver, packet_.guid, packet_.message, "")
        );
        uint256 before = gasleft();
        (ok, ret) = LZ_ENDPOINT.call{gas: gas_}(callData);
        used = before - gasleft();
    }

    /// @dev One cold trial from the verified state; always reverts the state.
    function _delivers(Case memory c_, uint256 gas_) internal returns (bool ok) {
        vm.revertToState(c_.snapshot);
        // `revertToState` consumes the snapshot id on some forge versions; take it again for the next trial.
        c_.snapshot = vm.snapshotState();
        _cool(c_.touched);
        (ok, , ) = _call(c_.origin, c_.packet, gas_);
        vm.revertToState(c_.snapshot);
        c_.snapshot = vm.snapshotState();
    }

    /// @dev Smallest delivery gas that does not revert, found on the real endpoint.
    function _smallestGas(Case memory c_) internal returns (uint256 hi) {
        uint256 lo = c_.budget; // the budget as TOTAL gas cannot reach the check
        hi = laneGas;
        assertTrue(_delivers(c_, hi), "the lane gas delivers");
        assertFalse(_delivers(c_, lo), "the budget as total gas does not");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_delivers(c_, mid)) hi = mid;
            else lo = mid;
        }
    }

    /// @notice At `G - 1` the delivery reverts `InsufficientGasForCommand` and stays retryable; at `G` the burn-all callee
    ///         ends in the catch path on the real endpoint: FAILED, exactly one decoded NACK, lane state untouched, and the
    ///         cold-adjusted headroom after the catch path above `MIN_HEADROOM`.
    /// @dev The measured figures are in the contract NatSpec.
    function testForkShouldFinishTheCatchPathOnTheRealEndpointAtTheSmallestDeliveryGas() public {
        Case memory c = _prepare();
        uint64 sequenceBefore = dispatcher.nextCommandSequence();
        uint256 idleBefore = dispatcher.trackedIdle();
        assertGt(idleBefore, 0, "real USDC is bridged in");
        assertEq(uint8(dispatcher.commandStatus(c.commandId)), uint8(CommandStatus.NONE), "not delivered yet");

        uint256 g = _smallestGas(c);

        // G - 1: the whole delivery reverts, nothing is written, the packet is still retryable.
        vm.revertToState(c.snapshot);
        c.snapshot = vm.snapshotState();
        _cool(c.touched);
        (bool okLow, bytes memory ret, ) = _call(c.origin, c.packet, g - 1);
        assertFalse(okLow, "G - 1 reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector, "reverts InsufficientGasForCommand");
        (uint256 have, uint256 need) = abi.decode(_tail(ret), (uint256, uint256));
        assertEq(need, c.budget, "needs the stamped budget");
        assertLt(have, need, "had less than the budget");
        emit log_named_uint("G - 1: gasleft at the budget check", have);
        assertEq(uint8(dispatcher.commandStatus(c.commandId)), uint8(CommandStatus.NONE), "nothing was written");
        assertEq(dispatcher.nextCommandSequence(), sequenceBefore, "lane sequence unchanged");

        // G: the callee burns its gas, the catch frame finishes on the reserve.
        vm.revertToState(c.snapshot);
        c.snapshot = vm.snapshotState();
        _cool(c.touched);
        // The business call really reaches the burning vault (not an earlier failure of the command).
        vm.expectCall(address(burnVault), abi.encodePacked(MockGasBurnVault.deposit.selector));
        vm.recordLogs();
        (bool ok, , uint256 used) = _call(c.origin, c.packet, g);
        assertTrue(ok, "G delivers");
        uint256 headroom = g - used;
        uint256 penalty = _coldAccountPenalty(c.touched);
        emit log_named_uint("stamped budget", c.budget);
        emit log_named_uint("G (smallest delivery gas, cold slots, warm accounts)", g);
        emit log_named_uint("cold upper bound of G (G + penalty)", g + penalty);
        emit log_named_uint("lane gas the executor stamps", laneGas);
        emit log_named_uint("gas used by the delivery at G", used);
        emit log_named_uint("catch headroom left after the delivery", headroom);
        emit log_named_uint("cold account penalty (over-count)", penalty);
        emit log_named_uint("catch headroom less the penalty", headroom > penalty ? headroom - penalty : 0);
        emit log_named_uint("COMMAND_CATCH_RESERVE_GAS", CrosschainConstants.COMMAND_CATCH_RESERVE_GAS);

        assertEq(uint8(dispatcher.commandStatus(c.commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(dispatcher.nextCommandSequence(), sequenceBefore, "FAILED does not advance the lane");
        assertEq(dispatcher.trackedIdle(), idleBefore, "the failed deposit moved nothing");
        assertEq(burnVault.totalSupply(), 0, "the callee never minted");

        _assertExactlyOneNack(c);

        // A fully cold delivery needs at most G + penalty, and the configured lane must cover it.
        assertLe(g + penalty, laneGas, "the cold upper bound of G fits the lane gas");
        assertGe(
            headroom,
            penalty + MIN_HEADROOM,
            "the 400k reserve leaves headroom on the real endpoint, cold-adjusted"
        );
    }

    /// @dev Decodes every packet the dispatcher sent during the recorded delivery: exactly one, a NACK for the command.
    function _assertExactlyOneNack(Case memory c_) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 nacks;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT || logs[i].topics[0] != PACKET_SENT_TOPIC) continue;
            (bytes memory encoded, , ) = abi.decode(logs[i].data, (bytes, bytes, address));
            Packet memory p = this.decodePacket(encoded);
            if (address(uint160(uint256(p.origin.sender))) != APP) continue;
            (MsgType t, bytes memory data) = CrosschainMessages.decodeEnvelope(p.message);
            assertEq(uint8(t), uint8(MsgType.NACK), "the packet is a NACK");
            CommandNack memory nack = CrosschainMessages.decodeCommandNack(data);
            assertEq(nack.commandId, c_.commandId, "NACK names the command");
            assertEq(nack.sequence, c_.sequence, "NACK names the sequence");
            assertEq(p.dstEid, ETHEREUM_EID, "NACK goes back to the executor chain");
            ++nacks;
        }
        assertEq(nacks, 1, "exactly one NACK through the real endpoint");
    }

    /// @dev Revert data without its 4-byte selector, as one ABI-decodable blob.
    function _tail(bytes memory ret_) internal pure returns (bytes memory out) {
        out = new bytes(ret_.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = ret_[i + 4];
        }
    }
}
