// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// Cold calibration of the IL-8625 pre-check constants against the real EndpointV2; console output is intended.
/* solhint-disable no-console */

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StargateForkBase} from "./StargateForkBase.sol";
import {ColdGas} from "../ColdGas.sol";
import {
    BusinessAction,
    CommandStatus,
    CrosschainConstants,
    MsgType
} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {
    StargateExecutorDeploymentLib
} from "../../../contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol";
import {MockRemoteVault} from "../mocks/MockRemoteVault.sol";

/// @title StargatePreCheckForkTest
/// @notice IL-8625 calibration of `COMMAND_PRE_CALL_BASE` / `COMMAND_PRE_CALL_PER_WORD` and of the `laneGas / 64` term
///         against the REAL EndpointV2 (verify, payload bookkeeping, `lzReceive`) and the real ULN fee quote of the
///         receipt-budget check, measured COLD.
/// @dev The measurements use forge 1.8.5 semantics (the CI forge). forge 1.7.1's `vm.cool` left the LayerZero fee-quote
///      path warm (about 130k under-measured on the first delivery), so the margins asserted here are valid under the CI
///      forge and conservative under 1.7.1; there are no version-specific branches.
///      `foundry.toml` has `isolate = false`, so a test is one transaction and anything touched earlier stays warm
///      unless it is cooled again (forge 1.7.1: `vm.revertToState` and a NEW fork reset warmth, `vm.selectFork` does not).
///      The measurement is therefore forced COLD in three ways. (1) Each shape is measured as the FIRST delivery on a
///      FRESH fork pair (new forks, so nothing is warm): it is the initial UPDATE_VAULTS of a freshly created dispatcher
///      (`createDispatcher(chain, vaults)` takes the born list), the only command that can be first on a path, so the ULN
///      receipt-budget quote of `_ensureReceiptBudget` (about 204k gas cold; the 72,164 quote in a trace is the SECOND,
///      post-check one of the ACK send) and every endpoint / dispatcher slot are cold. (2) Before every bisection trial
///      `vm.cool` re-cools every slot of every account the delivery touches (it clears slot warmth, not account warmth).
///      (3) The cold account accesses are added back analytically, `_coldAccountPenalty(touched)` = 2,500 per distinct
///      touched account; on a fresh fork most of them are cold already, so this deliberately double-counts them and the
///      margins below are conservative. Only the pre-check part is measured (smallest gas that still reaches the budget
///      check); the whole first delivery of the empty UPDATE_VAULTS costs far more than a later one, but
///      the gap is almost all AFTER the check (cold business writes and the ACK quote / send). A DEPOSIT (11 words) is a
///      later message on a real path and cannot be first, so its figure is EXTRAPOLATED from the linear fit through the
///      UPDATE_VAULTS shapes, not measured. For lanes of the minimum registrable gas, 4M and 10M a delivery at EXACTLY the
///      lane's gas must reach the dispatcher's budget check and the formula's allowance must exceed the measured cold work
///      by at least `MIN_MARGIN`.
contract StargatePreCheckForkTest is StargateForkBase, ColdGas {
    uint256 internal constant MIN_MARGIN = 100_000;

    struct Cold {
        uint256 budget;
        uint256 words;
        uint256 hi; // smallest delivery gas that reaches the check
        uint256 net; // cold work net of the endpoint -> OApp hop loss, incl. the cold accounts `cool` cannot reset
        uint256 allowance;
    }

    /// @dev Fresh forks, a freshly created dispatcher whose born list has `n_` vaults; returns its initial UPDATE_VAULTS.
    function _freshInitialUpdate(uint128 lane_, uint256 n_) internal returns (Packet memory packet, bytes32 id) {
        laneGas = lane_;
        _createForks();
        _deployApps();
        vm.selectFork(arbitrumFork);
        address[] memory list = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            list[i] = address(new MockRemoteVault(IERC20(ARBITRUM_USDC), "V", "V"));
        }
        vm.selectFork(ethereumFork);
        vm.prank(manager);
        executor.registerChain(ARBITRUM_CHAIN_ID, ARBITRUM_EID, _commandLaneOptions(ARBITRUM_EID));
        vm.prank(manager);
        executor.createDispatcher(ARBITRUM_CHAIN_ID, list);
        vm.recordLogs();
        factory.ackDispatcher(APP, 1, ARBITRUM_CHAIN_ID);
        packet = _takePacket(APP);
        (,,,, id,,) = executor.activeCommand(ARBITRUM_CHAIN_ID);
    }

    function _reaches(Packet memory p_, Origin memory o_, uint256 gas_, bytes32 id_, address[] memory touched_)
        internal
        returns (bool)
    {
        uint256 snap = vm.snapshotState();
        _cool(touched_);
        (bool ok,) = _lzReceive(o_, p_, gas_);
        bool committed = ok && dispatcher.commandStatus(id_) != CommandStatus.NONE;
        vm.revertToState(snap);
        return committed;
    }

    function _decode(Packet memory p_) internal pure returns (uint256 budget, uint256 words) {
        (MsgType t, bytes memory data) = CrosschainMessages.decodeEnvelope(p_.message);
        words = CrosschainMessages.payloadWords(data.length);
        budget = t == MsgType.COMMAND
            ? CrosschainMessages.decodeCommand(data).minExecutionGas
            : CrosschainMessages.decodeUpdateVaults(data).minExecutionGas;
    }

    function _measureCold(Packet memory p_, bytes32 id_, uint256 lane_) internal returns (Cold memory c) {
        (c.budget, c.words) = _decode(p_);
        vm.selectFork(arbitrumFork);
        // What `_verify` and the deployment leave warm (accounts): re-added at the cold account cost.
        _beginRecording();
        Origin memory origin = _verify(p_);
        address[] memory warmed = _endRecording();
        uint256 recorded = vm.snapshotState();
        _beginRecording();
        _lzReceive(origin, p_, lane_);
        address[] memory touched = _endRecording();
        vm.revertToState(recorded);
        assertTrue(_reaches(p_, origin, lane_, id_, touched), "reaches the check at EXACTLY the lane gas, cold");
        uint256 lo = c.budget;
        c.hi = lane_;
        while (c.hi - lo > 1) {
            uint256 mid = (lo + c.hi) / 2;
            if (_reaches(p_, origin, mid, id_, touched)) c.hi = mid;
            else lo = mid;
        }
        c.net = c.hi - c.budget - c.hi / 64 + _coldAccountPenalty(touched);
        c.allowance =
            CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * c.words;
    }

    function _runShape(string memory label_, uint128 lane_, uint256 n_) internal returns (Cold memory c) {
        (Packet memory packet, bytes32 id) = _freshInitialUpdate(lane_, n_);
        c = _measureCold(packet, id, lane_);
        console2.log(string.concat("PRECHECK | ", label_, " | lane / budget / words:"), lane_, c.budget, c.words);
        console2.log("   cold work net of hop loss (first delivery, cold):", c.net);
        console2.log("   formula allowance / margin:", c.allowance, c.allowance > c.net ? c.allowance - c.net : 0);
        assertGe(c.allowance, c.net + MIN_MARGIN, string.concat(label_, ": cold margin >= 100k"));
        assertLe(c.hi, lane_, string.concat(label_, ": the delivery at the lane gas reaches the check"));
    }

    function _runLane(uint128 lane_) internal {
        uint256[4] memory sizes = [uint256(0), 8, 16, 32];
        for (uint256 i; i < sizes.length; ++i) {
            _runShape(string.concat("UPDATE_VAULTS ", vm.toString(sizes[i])), lane_, sizes[i]);
        }
    }

    function testForkColdShouldReachTheCheckAtTheMinimumRegistrableLane() public {
        _runLane(uint128(StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS));
    }

    function testForkColdShouldReachTheCheckOnA4MLane() public {
        _runLane(4_000_000);
    }

    /// @dev 10M lane, fresh state: the hop loss at the lane is 156k.
    function testForkColdShouldReachTheCheckOnA10MLane() public {
        _runLane(10_000_000);
    }

    /// @notice The cold work is linear in the stored words, which lets the 11-word DEPOSIT (a later message that cannot be
    ///         first on a fresh path) be read off the fit; and the lane/64 term is load-bearing at the cap: the guaranteed
    ///         100k margin is smaller than the hop loss of a command topped up to `MAX_COMMAND_EXECUTION_GAS`, so a budget
    ///         stamped without that term would be undeliverable there.
    function testForkColdWorkIsLinearInTheWordsAndTheHopTermIsLoadBearingAtTheCap() public {
        Cold memory a = _runShape("UPDATE_VAULTS 0 (fit)", 4_000_000, 0);
        Cold memory b = _runShape("UPDATE_VAULTS 32 (fit)", 4_000_000, 32);
        uint256 slope = (b.net - a.net) / (b.words - a.words);
        uint256 intercept = a.net - slope * a.words;
        uint256 depositWords = 11;
        uint256 depositNet = intercept + slope * depositWords;
        console2.log("FIT | cold work = intercept + slope x words:", intercept, slope);
        console2.log("   DEPOSIT (11 words) cold work from the fit / allowance:", depositNet, CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * depositWords);
        uint256 depositMargin =
            CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * depositWords - depositNet;
        assertGe(depositMargin, MIN_MARGIN, "the DEPOSIT keeps the cold margin");
        uint256 hopAtCap =
            CrosschainMessages.laneGasFor(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS, depositWords, true) / 64;
        // The margin the constants guarantee (`MIN_MARGIN`, asserted above) is smaller than the hop loss at the cap, so a budget
        // stamped without the lane/64 term would not be guaranteed deliverable there. Compared against the guaranteed margin,
        // not the measured one, so the check does not depend on how warm the forge version leaves the measurement.
        assertLt(MIN_MARGIN, hopAtCap, "without the lane/64 term the guaranteed margin would not cover the hop loss at the cap");
    }

    /// @notice A command topped up to `MAX_COMMAND_EXECUTION_GAS` is delivered with the total gas `laneGasFor` asks for
    ///         (under the Ethereum transaction cap) and reaches the check with the cold-account penalty and the 100k
    ///         margin taken off the gas. It is a LATER message on a fork that already ran `_bringUp`, so the ULN, DVN,
    ///         fee-library and price-feed accounts are still warm (`selectFork` does not reset them): every slot is
    ///         re-cooled and the cold account accesses are subtracted from the gas instead.
    function testForkColdToppedUpCommandAtTheCapReachesTheCheck() public {
        laneGas = 4_000_000;
        _createForks();
        _deployApps();
        _bringUp();
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            ARBITRUM_CHAIN_ID,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: uint64(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS),
                actionData: CrosschainMessages.encodeDepositAction(ARBITRUM_FLUID_USDC, 1e6, 0)
            })
        );
        (,,,, bytes32 id,,) = executor.activeCommand(ARBITRUM_CHAIN_ID);
        Packet memory packet = _takePacket(APP);
        (uint256 budget, uint256 words) = _decode(packet);
        assertEq(budget, CrosschainConstants.MAX_COMMAND_EXECUTION_GAS, "the cap is the stamped budget");
        uint256 delivered = CrosschainMessages.laneGasFor(budget, words, true);
        assertLt(delivered + 1_000_000, 16_777_216, "deliverable on Ethereum (EIP-7825) with 1M of overhead");
        vm.selectFork(arbitrumFork);
        Origin memory origin = _verify(packet);
        uint256 recorded = vm.snapshotState();
        _beginRecording();
        _lzReceive(origin, packet, delivered);
        address[] memory touched = _endRecording();
        vm.revertToState(recorded);
        assertTrue(
            _reaches(packet, origin, delivered - _coldAccountPenalty(touched) - MIN_MARGIN, id, touched),
            "reaches the check at the total gas less the cold-account penalty and the 100k margin"
        );
    }
}
