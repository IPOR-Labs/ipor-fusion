// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {BusinessAction, CommandStatus, CrosschainConstants} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CrosschainMessages, UpdateVaults} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {StargateExecutorDeploymentLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol";
import {StargateExecutorCommandLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorCommandLib.sol";
import {StargateExecutorState} from "../../contracts/crosschain/stargate/lib/StargateExecutorState.sol";
import {MockGasBurnVault} from "./mocks/MockGasBurnVault.sol";
import {
    Weth9ShapedToken,
    UsdtShapedToken,
    ShapedTokenBase,
    MockShapedLiquidityVault,
    MockAuthorityGatedVault
} from "./mocks/MockBudgetVaults.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @dev Harness over the linked builders so the executor-side refusal can be driven with a lane gas the registration
///      path would never store.
contract StargateBudgetBuilderHarness {
    StargateExecutorState internal _s;

    function setLane(uint256 chainId_, uint128 gas_) external {
        _s.commandLaneReceiveGas[chainId_] = gas_;
    }

    function buildCommand(uint256 chainId_, uint256 requested_) external returns (bytes memory payload) {
        (payload,,,) = StargateExecutorCommandLib.buildBusinessCommand(_s, chainId_, 2, "", 1, requested_);
    }

    function buildUpdate(uint256 chainId_) external returns (bytes memory payload) {
        (payload,,) = StargateExecutorCommandLib.buildUpdateVaults(_s, chainId_, new address[](0), 1);
    }
}

/// @title StargateCommandOutOfGasTest
/// @notice IL-8625 (Ackee TP-M-47, TP-L-13, reviewer R1 / R5), Stargate half. The first execution of a verified
///         LayerZero packet is permissionless and carries no gas stipend, so a third party picks the gas the
///         dispatcher's handler sees. The rule is a gas budget CARRIED BY THE COMMAND (`minExecutionGas`, derived from
///         the registered lane gas, its 1/64 hop loss and the payload size, or topped up by the manager): a delivery
///         that reaches the business call with less gas reverts (retryable, nothing written); at or above the budget
///         EVERY failure of the business call is a business failure (FAILED + NACK), whatever the revert data says.
/// @dev `MockGasBurnVault.descend` burns all forwarded gas at depth 24. The default test lane registers 3,000,000
///      `lzReceive` gas. The mock endpoint does not model the real endpoint's lane/64 hop loss (the Stargate fork suite
///      does), so a mock delivery at the lane's gas has more slack than a real one.
contract StargateCommandOutOfGasTest is StargateTwoSidedBase {
    using OptionsBuilder for bytes;

    uint256 internal constant GENEROUS_GAS = 8_000_000;
    uint256 internal constant OTHER_CHAIN = 10;
    uint32 internal constant OTHER_EID = 30111;
    /// @dev Margin under the call's gas in the threshold tests (dispatcher + vault frames before the authority call).
    uint256 internal constant CALL_MARGIN = 250_000;

    MockGasBurnVault internal burnVault;

    event CommandFailed(bytes32 commandId, uint64 sequence);

    function setUp() public {
        _twoSidedSetUp();
        burnVault = new MockGasBurnVault(usdc);
        remoteVault = burnVault; // helpers allowlist and deposit into `remoteVault`
        _bringUpBothSides();
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
    }

    function _sendDeposit(uint256 amountSD_) internal returns (bytes32 commandId, uint256 packetIndex) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(amountSD_));
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        packetIndex = _lastSentIndex();
    }

    function _redeem(uint256 shares_) internal returns (bytes32 commandId, uint256 packetIndex) {
        return _redeemWithBudget(shares_, 0);
    }

    function _redeemWithBudget(uint256 shares_, uint64 budget_) internal returns (bytes32 commandId, uint256 packetIndex) {
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: budget_,
                actionData: CrosschainMessages.encodeRedeemAction(address(remoteVault), shares_, 0)
            })
        );
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        packetIndex = _lastSentIndex();
    }

    function _deliver(uint256 index_, uint256 gas_) internal returns (bool ok, bytes memory ret) {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(index_);
        (ok, ret) = address(endpoint).call{gas: gas_}(
            abi.encodeCall(
                MockLzEndpoint.deliverLz,
                (address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message)
            )
        );
    }

    function _deliverAndRevert(uint256 index_, uint256 gas_) internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = _deliver(index_, gas_);
        vm.revertToState(snap);
    }

    function _storedCommand(uint256 index_) internal view returns (Command memory) {
        (, bytes memory data) = CrosschainMessages.decodeEnvelope(endpoint.sentAt(index_).message);
        return CrosschainMessages.decodeCommand(data);
    }

    function _budgetOf(uint256 index_) internal view returns (uint256) {
        return _storedCommand(index_).minExecutionGas;
    }

    /// @dev The total executor `lzReceive` gas the packet's options ask the LayerZero executor to deliver with.
    function _optionsGas(uint256 index_) internal view returns (uint256) {
        return endpoint.lzReceiveGasOf(endpoint.sentAt(index_).options);
    }

    /// @dev The smallest delivery gas at which the dispatcher reaches its budget check (and commits) for the packet.
    function _threshold(uint256 index_) internal returns (uint256 hi) {
        uint256 lo = _budgetOf(index_); // refused: the budget as TOTAL gas cannot reach the check
        hi = _optionsGas(index_) + 1_000_000; // accepted
        (bool okHi,) = _deliverAndRevert(index_, hi);
        (bool okLo,) = _deliverAndRevert(index_, lo);
        assertTrue(okHi, "generous gas reaches the check");
        assertFalse(okLo, "the budget as total gas does not");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _deliverAndRevert(index_, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    /// @dev NACK -> executor, manager CANCEL -> dispatcher -> receipt -> executor: frees the lane in the same block.
    function _failedThenCancelled() internal {
        _relayAll(); // the NACK
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll(); // CANCEL -> dispatcher, CANCELLED -> executor
        assertFalse(_commandSlotActive(), "lane freed in the same block");
    }

    function _words(Command memory c_) internal pure returns (uint256) {
        c_.minExecutionGas = 0;
        return CrosschainMessages.payloadWords(abi.encode(c_).length);
    }

    // ---------------------------------------------------------------------
    // The budget is stamped from the registered lane and the payload
    // ---------------------------------------------------------------------

    function testShouldStampTheBudgetOfCommandAndUpdateVaultsFromTheRegisteredLane() public {
        (, uint256 index) = _sendDeposit(10e6);
        Command memory c = _storedCommand(index);
        assertEq(
            c.minExecutionGas,
            CrosschainMessages.commandGasBudget(commandLaneGas, _words(c), true),
            "COMMAND budget = formula(lane, words)"
        );
        _relayAll();

        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        (, bytes memory data) = CrosschainMessages.decodeEnvelope(endpoint.sentAt(_lastSentIndex()).message);
        uint256 words = CrosschainMessages.payloadWords(data.length);
        assertEq(
            CrosschainMessages.decodeUpdateVaults(data).minExecutionGas,
            CrosschainMessages.commandGasBudget(commandLaneGas, words, true),
            "UPDATE_VAULTS budget = formula(lane, its own words)"
        );
    }

    /// @notice The registered lane gas is stored PER CHAIN and used for that chain's commands.
    function testShouldStoreTheRegisteredLaneGasPerChainAndUseIt() public {
        factory.setPath(OTHER_CHAIN, OTHER_EID);
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: OTHER_EID, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(4_000_000, 0)
        });
        vm.prank(manager);
        executor.registerChain(OTHER_CHAIN, OTHER_EID, abi.encode(options));
        vm.prank(manager);
        executor.createDispatcher(OTHER_CHAIN, new address[](0));
        factory.ackDispatcher(address(executor), 2, OTHER_CHAIN);

        // The auto-sent initial UPDATE_VAULTS of the second chain uses ITS lane (4M), not the first chain's (3M).
        (, bytes memory data) = CrosschainMessages.decodeEnvelope(endpoint.sentAt(_lastSentIndex()).message);
        assertEq(
            CrosschainMessages.decodeUpdateVaults(data).minExecutionGas,
            CrosschainMessages.commandGasBudget(4_000_000, CrosschainMessages.payloadWords(data.length), true),
            "second chain budget"
        );
        (, uint256 index) = _sendDeposit(10e6);
        Command memory c = _storedCommand(index);
        assertEq(
            c.minExecutionGas,
            CrosschainMessages.commandGasBudget(commandLaneGas, _words(c), true),
            "first chain budget unchanged"
        );
    }

    /// @notice The builders refuse a lane whose budget would be below the floor for the payload, and reject a manager
    ///         top-up above the cap.
    function testShouldRefuseToBuildWhenTheLaneIsTooSmallForThePayload() public {
        StargateBudgetBuilderHarness h = new StargateBudgetBuilderHarness();
        Command memory probe = Command({
            commandId: bytes32(0), sequence: 0, commandConfigEpoch: 0, action: 2, minExecutionGas: 0, actionData: ""
        });
        uint256 minLane =
            CrosschainMessages.laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, _words(probe), true);
        h.setLane(REMOTE_CHAIN, uint128(minLane - 1));
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, minLane - 1, minLane));
        h.buildCommand(REMOTE_CHAIN, 0);
        // An unregistered chain (no stored lane gas) is refused too.
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, 0, minLane));
        h.buildCommand(12345, 0);

        h.setLane(REMOTE_CHAIN, uint128(minLane));
        h.buildCommand(REMOTE_CHAIN, 0); // exactly the minimum is accepted

        // The empty UPDATE_VAULTS is a smaller payload than any command here, so its minimum is lower.
        UpdateVaults memory emptyUpdate = UpdateVaults({
            commandId: bytes32(0),
            sequence: 0,
            newConfigEpoch: 0,
            minExecutionGas: 0,
            vaults: new address[](0)
        });
        uint256 minUpdateLane = CrosschainMessages.laneGasFor(
            CrosschainConstants.COMMAND_EXECUTION_MIN_GAS,
            CrosschainMessages.payloadWords(abi.encode(emptyUpdate).length),
            true
        );
        assertLt(minUpdateLane, minLane, "the UPDATE_VAULTS floor is lower than the command floor");

        h.setLane(REMOTE_CHAIN, 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, 0, minUpdateLane));
        h.buildUpdate(REMOTE_CHAIN);

        h.setLane(REMOTE_CHAIN, uint128(minUpdateLane - 1));
        vm.expectRevert(
            abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, minUpdateLane - 1, minUpdateLane)
        );
        h.buildUpdate(REMOTE_CHAIN);

        h.setLane(REMOTE_CHAIN, uint128(minUpdateLane));
        h.buildUpdate(REMOTE_CHAIN); // exactly the minimum is accepted

        h.setLane(777, 4_000_000);
        uint256 cap = CrosschainConstants.MAX_COMMAND_EXECUTION_GAS;
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveMax.selector, cap + 1, cap));
        h.buildCommand(777, cap + 1);
    }

    // ---------------------------------------------------------------------
    // Below the budget: revert, retryable. At / above the budget: FAILED + NACK, out-of-gas included
    // ---------------------------------------------------------------------

    function testShouldRevertBelowTheBudgetAndStayRetryable() public {
        burnVault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 seqBefore = dispatcher.nextCommandSequence();

        // Delivered with the budget as TOTAL gas, the dispatcher's own pre-call work leaves less than the budget.
        (bool ok, bytes memory ret) = _deliver(index, _budgetOf(index));

        assertFalse(ok, "below the budget the delivery reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector, "budget error");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "no status written");
        assertEq(dispatcher.nextCommandSequence(), seqBefore, "sequence untouched");
        assertEq(dispatcher.trackedIdle(), idleBefore, "no capital moved");
        assertEq(endpoint.sentCount(), sentBefore, "no NACK sent");

        // Re-deliverable: the same packet with the lane's gas runs.
        burnVault.setMode(MockGasBurnVault.Mode.NORMAL);
        (ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok, "re-delivery with the lane gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ran on re-delivery");
    }

    function testShouldRecordFailedAndNackForAnOutOfGasActionAtTheBudget() public {
        burnVault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(commandId, dispatcher.nextCommandSequence());
        (bool ok,) = _deliver(index, commandLaneGas);

        assertTrue(ok, "at the budget an out-of-gas action is a clean delivery");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    /// @notice The attacker's best delivery: the smallest gas that still reaches the check. An out-of-gas action there is
    ///         a business failure (FAILED + NACK), never a revert.
    function testShouldRecordFailedAndNackForAnOutOfGasActionAtTheThreshold() public {
        burnVault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();
        uint256 threshold = _threshold(index);

        (bool ok,) = _deliver(index, threshold);

        assertTrue(ok, "at the threshold an out-of-gas action is a clean delivery");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    /// @notice The delivery threshold sits between the budget and the lane gas: the formula covers the dispatcher's
    ///         pre-call work, so a delivery at the lane's gas reaches the check, and one gas unit less than the
    ///         threshold does not.
    function testShouldPlaceTheDeliveryThresholdBetweenTheBudgetAndTheLaneGas() public {
        (, uint256 index) = _sendDeposit(10e6);
        uint256 budget = _budgetOf(index);
        uint256 threshold = _threshold(index);
        (bool okLane,) = _deliverAndRevert(index, commandLaneGas);
        (bool okBelow, bytes memory ret) = _deliverAndRevert(index, threshold - 1);
        assertTrue(okLane, "the lane gas reaches the check");
        assertFalse(okBelow);
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        emit log_named_uint("Stargate DEPOSIT threshold delivery gas:", threshold);
        emit log_named_uint("Stargate DEPOSIT pre-call work (threshold - budget):", threshold - budget);
        emit log_named_uint("Stargate DEPOSIT allowance (lane - budget):", commandLaneGas - budget);
        assertGt(threshold, budget, "the dispatcher spends gas before the check");
        assertLe(threshold, commandLaneGas, "pre-call work is covered by the lane");
    }

    /// @notice A decodable business error is still FAILED + NACK.
    function testShouldStillPersistFailedAndNackForADecodableBusinessError() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();

        (bool ok,) = _deliver(index, commandLaneGas);

        assertTrue(ok, "business failure is a clean delivery");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    /// @notice No classification of the revert data: the OpenZeppelin wrappers and `InsufficientGasForVaultRead`, which
    ///         used to be bubbled, are business failures at the budget (the lane is too small for the action / tracked
    ///         set, which the manager fixes with a top-up).
    function testShouldTreatWrappedOutOfGasAndVaultReadGasErrorsAsBusinessFailuresAtTheBudget() public {
        MockGasBurnVault.Mode[3] memory modes = [
            MockGasBurnVault.Mode.OZ_FAILED_INNER_CALL,
            MockGasBurnVault.Mode.OZ_FAILED_CALL,
            MockGasBurnVault.Mode.VAULT_READ_GAS_ERROR
        ];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            burnVault.setMode(modes[i]);
            (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
            uint256 sentBefore = endpoint.sentCount();

            (bool ok,) = _deliver(index, commandLaneGas);

            assertTrue(ok, "clean delivery at the budget");
            assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
            assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
            vm.revertToState(snap);
        }
    }

    /// @notice TP-L-13: a callee that burns all the gas it was given and then reverts with a selector is still FAILED +
    ///         NACK, because the self-call is capped and the catch frame keeps `COMMAND_CATCH_RESERVE_GAS`.
    function testShouldPersistFailedAndNackWhenACalleeBurnsAllItsGasThenRevertsWithASelector() public {
        burnVault.setMode(MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();

        (bool ok,) = _deliver(index, commandLaneGas);

        assertTrue(ok, "the reserve lets the catch frame finish");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    /// @dev Delivered at the threshold of a floor-budget command, the catch frame has nothing but the reserve (the callee
    ///      burned everything else it was given) and must still complete FAILED + NACK.
    function testShouldFinishTheCatchPathOnTheReserveAloneAtTheFloor() public {
        burnVault.setMode(MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 sentBefore = endpoint.sentCount();
        // Rebuild the packet with the floor budget; this command id has not been delivered yet.
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(index);
        Command memory c = _storedCommand(index);
        c.minExecutionGas = uint64(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS);
        bytes memory message = CrosschainMessages.encodeCommand(c);
        uint256 g0 = gasleft();
        (bool ok,) = address(endpoint).call{gas: CrosschainConstants.COMMAND_EXECUTION_MIN_GAS + 800_000}(
            abi.encodeCall(
                MockLzEndpoint.deliverLz,
                (address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, message)
            )
        );
        emit log_named_uint("Stargate delivery gas at the floor, callee burned all:", g0 - gasleft());
        assertTrue(ok, "reserve alone pays for the FAILED + NACK path at the floor");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    function testShouldNotLetALargeRevertPayloadEatTheReserve() public {
        burnVault.setMode(MockGasBurnVault.Mode.BIG_PAYLOAD_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);

        (bool ok,) = _deliver(index, commandLaneGas);

        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
    }

    /// @dev Measurement behind `COMMAND_CATCH_RESERVE_GAS`: a whole business-failure delivery.
    function testShouldMeasureTheWholeFailedDeliveryGas() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (, uint256 index) = _sendDeposit(10e6);
        uint256 g0 = gasleft();
        (bool ok,) = _deliver(index, commandLaneGas);
        uint256 failedDelivery = g0 - gasleft();
        assertTrue(ok);
        emit log_named_uint("Stargate whole FAILED + NACK delivery gas (business revert, mocks):", failedDelivery);
        assertLt(failedDelivery, CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, "a plain failure fits the budget");
    }

    // ---------------------------------------------------------------------
    // Budget binding: tamper and RETRY
    // ---------------------------------------------------------------------

    /// @notice The budget is inside the committed bytes: a redelivery of a stored command with a lowered budget is a
    ///         commitment mismatch, never a lower-budget re-run.
    function testShouldRejectARedeliveryWithALoweredBudget() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));

        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(index);
        Command memory c = _storedCommand(index);
        c.minExecutionGas = uint64(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS);
        bytes memory tampered = CrosschainMessages.encodeCommand(c);
        (bool okT, bytes memory ret) = address(endpoint).call{gas: GENEROUS_GAS}(
            abi.encodeCall(
                MockLzEndpoint.deliverLz,
                (address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, tampered)
            )
        );
        assertFalse(okT, "a tampered budget cannot be redelivered");
        assertEq(bytes4(ret), CrosschainErrors.CommandCommitmentMismatch.selector, "commitment mismatch");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "stored record untouched");
    }

    /// @notice RETRY_COMMAND re-runs the STORED budget: below it the retry reverts (and the FAILED record survives), at
    ///         the lane gas it runs.
    function testShouldRetryWithTheStoredBudget() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(50e6);
        uint256 budget = _budgetOf(index);
        relayCursor = endpoint.sentCount(); // deliver by hand, relay only what follows
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        _relayAll(); // NACK -> executor

        burnVault.setMode(MockGasBurnVault.Mode.NORMAL);
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
        uint256 retryIndex = _lastSentIndex();

        (bool okLow, bytes memory ret) = _deliver(retryIndex, budget);
        assertFalse(okLow, "a retry below the stored budget reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        (, uint256 required) = abi.decode(_args(ret), (uint256, uint256));
        assertEq(required, budget, "the retry is held to the stored budget");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED record survives");

        (ok,) = _deliver(retryIndex, commandLaneGas);
        assertTrue(ok, "retry at the lane gas runs");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "retry succeeded");
    }

    function _args(bytes memory revertData_) internal pure returns (bytes memory args_) {
        args_ = new bytes(revertData_.length - 4);
        for (uint256 i; i < args_.length; ++i) {
            args_[i] = revertData_[i + 4];
        }
    }

    // ---------------------------------------------------------------------
    // R1: a REDEEM above the vault's instant liquidity on a WETH9- / USDT-shaped token
    // ---------------------------------------------------------------------

    function _r1(ShapedTokenBase token_) internal {
        MockShapedLiquidityVault shaped = new MockShapedLiquidityVault(IERC20(address(usdc)), IERC20(address(token_)));
        remoteVault = shaped;
        _allowRemoteVault();
        token_.mint(address(shaped), 20e6); // instant liquidity
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        _relayAll();
        assertEq(shaped.balanceOf(address(dispatcher)), 50e6, "position opened");

        // 50e6 shares above the 20e6 of instant liquidity: the token reverts with EMPTY data, SafeERC20 wraps it.
        (bytes32 commandId, uint256 index) = _redeem(50e6);
        relayCursor = endpoint.sentCount();
        uint256 sentBefore = endpoint.sentCount();
        (bool ok,) = _deliver(index, commandLaneGas);

        assertTrue(ok, "the delivery no longer reverts at any gas: it is a business failure at the budget");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent within the delivery");

        // The manager frees the lane in the same block and sends a smaller REDEEM that succeeds.
        _failedThenCancelled();
        (bytes32 smaller, uint256 smallerIndex) = _redeem(20e6);
        (ok,) = _deliver(smallerIndex, commandLaneGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(smaller)), uint8(CommandStatus.SUCCEEDED), "smaller REDEEM succeeded");
        assertEq(shaped.balanceOf(address(dispatcher)), 30e6, "20e6 shares redeemed");
    }

    function testShouldNackARedeemAboveInstantLiquidityOnAWeth9ShapedToken() public {
        _r1(ShapedTokenBase(address(new Weth9ShapedToken())));
    }

    function testShouldNackARedeemAboveInstantLiquidityOnAUsdtShapedToken() public {
        _r1(ShapedTokenBase(address(new UsdtShapedToken())));
    }

    // ---------------------------------------------------------------------
    // R5: an out-of-gas inside the AccessManager check surfaces as a decodable AccessManagedUnauthorized
    // ---------------------------------------------------------------------

    function _gatedPosition() internal returns (MockAuthorityGatedVault gated) {
        gated = new MockAuthorityGatedVault(IERC20(address(usdc)));
        remoteVault = gated;
        _allowRemoteVault();
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(50e6));
        _relayAll();
        assertEq(gated.balanceOf(address(dispatcher)), 50e6, "position opened");
    }

    /// @notice With a correctly sized lane the REDEEM succeeds at the budget; delivered BELOW the budget it reverts and
    ///         stays retryable instead of being committed as an `AccessManagedUnauthorized` FAILED + NACK.
    function testShouldNeverCommitAnAccessManagerOutOfGasBelowTheBudget() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(600_000); // a cold check the lane covers
        (bytes32 commandId, uint256 index) = _redeem(50e6);
        uint256 sentBefore = endpoint.sentCount();

        // Attacker-chosen gas just below the budget: the authority would run out of gas and look "unauthorized".
        (bool ok, bytes memory ret) = _deliver(index, _budgetOf(index));
        assertFalse(ok, "reverts instead of recording a forged refusal");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "no status written");
        assertEq(endpoint.sentCount(), sentBefore, "no NACK");

        (ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok, "at the budget on a correctly sized lane it succeeds");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "REDEEM succeeded");
        assertEq(gated.balanceOf(address(dispatcher)), 0);
    }

    /// @notice The attacker's best gas: the exact threshold. With the authority needing the budget minus the reserve and
    ///         a margin the REDEEM still succeeds; if the check needs slightly more than the call gets, the same delivery
    ///         is a FAILED + NACK. That is the documented residual: the lane must be sized to the measured check.
    function testShouldSucceedAtTheThresholdWhenTheLaneIsSizedAndNackWhenItIsNot() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        (bytes32 commandId, uint256 index) = _redeem(50e6);
        uint256 budget = _budgetOf(index);
        uint256 threshold = _threshold(index);
        uint256 callGas = budget - CrosschainConstants.COMMAND_CATCH_RESERVE_GAS;

        // Sized: the check needs `callGas - margin`.
        uint256 snap = vm.snapshotState();
        gated.AUTHORITY().setGasNeeded(callGas - CALL_MARGIN);
        (bool ok,) = _deliver(index, threshold);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "sized lane: REDEEM succeeded");
        vm.revertToState(snap);

        // Undersized: the check needs more than the call has.
        gated.AUTHORITY().setGasNeeded(callGas + 100_000);
        uint256 sentBefore = endpoint.sentCount();
        (ok,) = _deliver(index, threshold);
        assertTrue(ok, "delivered at the threshold");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "undersized lane: NACK");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
    }

    // ---------------------------------------------------------------------
    // Per-command gas top-up (MAX_COMMAND_EXECUTION_GAS) and the RETRY raise
    // ---------------------------------------------------------------------

    uint64 internal constant TOP_UP = 3_300_000;

    /// @notice A heavy command on an undersized lane NACKs; with a manager top-up the SAME command executes at the honest
    ///         delivery (lane + extra) and at the attacker's exact threshold.
    function testShouldExecuteAHeavyCommandWithAManagerTopUpAtTheHonestDeliveryAndTheThreshold() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(2_300_000); // more than the lane budget leaves the call
        // Without a top-up the lane budget is not enough.
        uint256 snap = vm.snapshotState();
        (bytes32 plainId, uint256 plainIndex) = _redeem(50e6);
        (bool ok,) = _deliver(plainIndex, commandLaneGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(plainId)), uint8(CommandStatus.FAILED), "undersized lane NACKs");
        vm.revertToState(snap);

        (bytes32 commandId, uint256 index) = _redeemWithBudget(50e6, TOP_UP);
        assertEq(_budgetOf(index), TOP_UP, "the requested budget is stamped");
        uint256 honestGas = _optionsGas(index);
        assertGt(honestGas, commandLaneGas, "the extra option raised the delivered lzReceive gas");
        uint256 expected = CrosschainMessages.laneGasFor(TOP_UP, _words(_storedCommand(index)), true);
        assertEq(honestGas, expected, "lane + extra = the exact inverse of the formula");

        // Attacker at the exact threshold of the raised budget: still succeeds.
        snap = vm.snapshotState();
        uint256 threshold = _threshold(index);
        assertLt(threshold, honestGas, "the threshold is below the honest gas: the formula leaves slack");
        (ok,) = _deliver(index, threshold);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "threshold delivery executes");
        vm.revertToState(snap);

        // Honest delivery with the total option gas.
        (ok,) = _deliver(index, honestGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "honest delivery executes");
        assertEq(gated.balanceOf(address(dispatcher)), 0);
    }

    /// @notice A requested budget at or below the lane budget adds no option; above `MAX_COMMAND_EXECUTION_GAS` reverts.
    function testShouldHonourTheTopUpCapAndAddNoOptionBelowTheLaneBudget() public {
        _gatedPosition();
        (, uint256 plain) = _redeem(10e6);
        uint256 laneBudget = _budgetOf(plain);
        assertEq(_optionsGas(plain), commandLaneGas, "no top-up, no extra option");
        _relayAll();

        (, uint256 low) = _redeemWithBudget(10e6, uint64(laneBudget - 1));
        assertEq(_budgetOf(low), laneBudget, "a request below the lane budget keeps the lane budget");
        assertEq(_optionsGas(low), commandLaneGas, "and adds no option");
        _relayAll();

        uint256 cap = CrosschainConstants.MAX_COMMAND_EXECUTION_GAS;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveMax.selector, cap + 1, cap));
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: uint64(cap + 1),
                actionData: CrosschainMessages.encodeRedeemAction(address(remoteVault), 10e6, 0)
            })
        );

        // Exactly the cap is accepted and stamped.
        (, uint256 atCap) = _redeemWithBudget(10e6, uint64(cap));
        assertEq(_budgetOf(atCap), cap);
        assertGt(_optionsGas(atCap), cap, "the delivered gas covers the cap plus the pre-call work");
    }

    /// @notice The send fee is quoted over the combined options, so the top-up's extra gas is inside the
    ///         `maxNativeFee` check.
    function testShouldCountTheTopUpInTheNativeFeeCheck() public {
        _gatedPosition();
        endpoint.setFeePerLzReceiveGas(1e6); // wei per lzReceive gas
        uint256 laneFee = endpoint.messagingFee() + 1e6 * commandLaneGas;
        factory.setExecutor(address(executor), true);
        factory.setMaxNativeFee(REMOTE_CHAIN, laneFee + 1e6); // fits the lane, not the top-up

        (bytes32 plainId,) = _redeem(10e6); // no top-up: inside the cap
        assertTrue(plainId != bytes32(0));
        _relayAll();

        vm.prank(manager);
        vm.expectPartialRevert(CrosschainErrors.NativeFeeTooHigh.selector);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: TOP_UP,
                actionData: CrosschainMessages.encodeRedeemAction(address(remoteVault), 10e6, 0)
            })
        );
    }

    /// @notice RETRY_COMMAND with a raised budget recovers a NACKed heavy command.
    function testShouldRecoverANackedHeavyCommandWithARetryThatRaisesTheBudget() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(2_300_000);
        (bytes32 commandId, uint256 index) = _redeem(50e6);
        relayCursor = endpoint.sentCount();
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACKed on the undersized lane");
        _relayAll(); // NACK -> executor

        vm.prank(manager);
        executor.retryCommandWithBudget(REMOTE_CHAIN, TOP_UP);
        uint256 retryIndex = _lastSentIndex();
        uint256 honestGas = _optionsGas(retryIndex);
        assertGt(honestGas, commandLaneGas, "the retry carries the extra lzReceive option");

        (ok,) = _deliver(retryIndex, honestGas);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "raised retry recovered it");
        assertEq(gated.balanceOf(address(dispatcher)), 0);
    }

    /// @notice The raised budget is PERSISTED on the dispatcher: a later plain retry (raise 0) is still held to it, and the
    ///         executor keeps sending the extra gas for it.
    function testShouldPersistTheRaisedBudgetForLaterRetries() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(20_000_000); // nothing fits: every run NACKs
        (bytes32 commandId, uint256 index) = _redeem(50e6);
        relayCursor = endpoint.sentCount();
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        _relayAll();

        vm.prank(manager);
        executor.retryCommandWithBudget(REMOTE_CHAIN, TOP_UP);
        uint256 raisedRetry = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        (ok,) = _deliver(raisedRetry, _optionsGas(raisedRetry));
        assertTrue(ok, "the raised retry is delivered (and NACKs again)");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));
        _relayAll();

        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN); // plain: raise 0
        uint256 plainRetry = _lastSentIndex();
        assertEq(_optionsGas(plainRetry), _optionsGas(raisedRetry), "the executor keeps funding the stored raise");
        (bool okLow, bytes memory ret) = _deliver(plainRetry, commandLaneGas);
        assertFalse(okLow, "the plain retry at the lane gas is held to the persisted raise");
        (, uint256 required) = abi.decode(_args(ret), (uint256, uint256));
        assertEq(required, TOP_UP, "dispatcher persisted max(stored, raise)");
    }

    /// @notice A RETRY can only raise: a lower raise changes nothing, the dispatcher keeps the higher stored budget.
    function testShouldNotLetARetryLowerTheBudget() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(20_000_000); // every run NACKs
        (bytes32 commandId, uint256 index) = _redeemWithBudget(50e6, TOP_UP);
        relayCursor = endpoint.sentCount();
        (bool ok,) = _deliver(index, _optionsGas(index));
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));
        _relayAll();

        vm.prank(manager);
        executor.retryCommandWithBudget(REMOTE_CHAIN, uint64(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS));
        uint256 retryIndex = _lastSentIndex();
        assertEq(_optionsGas(retryIndex), _optionsGas(index), "the executor still funds the higher stored budget");
        // Enough gas for the LOWER budget, not for the stored one.
        (bool okLow, bytes memory ret) = _deliver(retryIndex, 1_900_000);
        assertFalse(okLow, "a lower raise does not lower the budget");
        (, uint256 required) = abi.decode(_args(ret), (uint256, uint256));
        assertEq(required, TOP_UP, "still the stored, higher budget");
    }

    function testShouldRejectARetryRaiseAboveTheCap() public {
        _gatedPosition();
        MockAuthorityGatedVault(address(remoteVault)).AUTHORITY().setGasNeeded(20_000_000);
        (, uint256 index) = _redeem(50e6);
        relayCursor = endpoint.sentCount();
        _deliver(index, commandLaneGas);
        _relayAll();
        uint256 cap = CrosschainConstants.MAX_COMMAND_EXECUTION_GAS;
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveMax.selector, cap + 1, cap));
        executor.retryCommandWithBudget(REMOTE_CHAIN, uint64(cap + 1));
    }

    // ---------------------------------------------------------------------
    // Expiry before budget (IL-8625): an undeliverable budget can never wedge the lane
    // ---------------------------------------------------------------------

    /// @notice A command whose budget can never be delivered (here the cap, on a lane that cannot fund it) reverts before its
    ///         deadline, as a below-budget delivery must; at the deadline itself the budget is still checked (the deadline
    ///         is inclusive); one second later a delivery with enough gas to send the NACK records FAILED + NACK
    ///         without a business call, and the manager's CANCEL gets the IL-8594 `EXPIRED` receipt that frees the lane:
    ///         no admin, no ABANDON, the sequence is not consumed.
    function testShouldNackAnExpiredCommandWithAnUndeliverableBudgetAndFreeTheLaneWithoutTheAdmin() public {
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: uint64(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS),
                actionData: CrosschainMessages.encodeDepositAction(address(remoteVault), 10e6, 0)
            })
        );
        (,,,, bytes32 commandId, uint64 seq,) = executor.activeCommand(REMOTE_CHAIN);
        uint256 index = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        uint256 deadline = CrosschainMessages.commandDeadline(commandId);
        uint256 lowGas = 1_500_000; // far below the 14M budget, above the pre-check work and the NACK guard

        // Before the deadline, and AT it: the budget check still decides.
        (bool ok, bytes memory ret) = _deliver(index, lowGas);
        assertFalse(ok, "not expired: below the budget reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        vm.warp(deadline);
        (ok, ret) = _deliver(index, lowGas);
        assertFalse(ok, "at the deadline (inclusive) the budget check still applies");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "nothing stored yet");

        // One second past it: NACK at the same low gas, no business call.
        vm.warp(deadline + 1);
        uint256 sentBefore = endpoint.sentCount();
        (ok,) = _deliver(index, lowGas);
        assertTrue(ok, "an expired command is recorded at low gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
        assertEq(dispatcher.nextCommandSequence(), seq, "sequence not consumed");
        assertEq(dispatcher.trackedIdle(), 100e6, "no business call, no capital moved");

        // The manager's CANCEL (past the deadline) is answered EXPIRED and frees the lane without the admin.
        _relayAll(); // NACK -> executor
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "NACK applied");
        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll(); // CANCEL -> dispatcher -> EXPIRED receipt -> executor
        assertFalse(_commandSlotActive(), "lane freed by the manager, no ABANDON");
        assertEq(dispatcher.nextCommandSequence(), seq, "the expired cancel does not consume the sequence");
        assertEq(executor.nextSequenceToSend(REMOTE_CHAIN), seq, "mirror unchanged: the next command reuses it");
    }

    /// @notice An expired command is still subject to the NACK guard: below `MIN_NACK_GAS` the delivery reverts.
    function testShouldStillGuardTheNackGasOfAnExpiredCommand() public {
        (bytes32 commandId, uint256 index) = _sendDeposit(10e6);
        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        (bool ok, bytes memory ret) = _deliver(index, 450_000); // the pre-check work leaves less than the guard
        assertFalse(ok);
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForNack.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "nothing stored");
    }

    /// @notice A RETRY raise that can never be delivered (the cap, on a lane that cannot fund it) reverts before the
    ///         deadline; sent in time and delivered after it, the retry is NACKed at low gas (the persisted raise is
    ///         harmless: an expired command never runs) and the manager's CANCEL frees the lane (EXPIRED receipt).
    function testShouldNackAnUndeliverableRetryRaiseDeliveredAfterTheDeadlineAndFreeTheLane() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(10e6);
        (,,,,, uint64 seq,) = executor.activeCommand(REMOTE_CHAIN);
        relayCursor = endpoint.sentCount();
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        _relayAll(); // NACK -> executor
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED));

        vm.prank(manager);
        executor.retryCommandWithBudget(REMOTE_CHAIN, uint64(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS));
        uint256 retryIndex = _lastSentIndex();
        relayCursor = endpoint.sentCount();
        bytes memory ret;
        (ok, ret) = _deliver(retryIndex, 1_500_000);
        assertFalse(ok, "before the deadline the undeliverable raise reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);

        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        uint256 sentBefore = endpoint.sentCount();
        (ok,) = _deliver(retryIndex, 1_500_000);
        assertTrue(ok, "after the deadline the retry is NACKed at low gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));
        assertEq(endpoint.sentCount(), sentBefore + 1, "NACK sent");
        _relayAll();
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "NACK applied");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN);
        _relayAll();
        assertFalse(_commandSlotActive(), "lane freed by the manager, no ABANDON");
        assertEq(dispatcher.nextCommandSequence(), seq, "the expired cancel does not consume the sequence");
    }

    /// @notice The executor refuses a RETRY of a command already past its deadline (it can only end in a NACK): plain and
    ///         raised. At the deadline itself (inclusive) it is still allowed, and the CANCEL is never refused.
    function testShouldRefuseARetryOfACommandPastItsDeadline() public {
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 index) = _sendDeposit(10e6);
        relayCursor = endpoint.sentCount();
        (bool ok,) = _deliver(index, commandLaneGas);
        assertTrue(ok);
        _relayAll();
        uint256 deadline = CrosschainMessages.commandDeadline(commandId);

        vm.warp(deadline + 1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandExpired.selector, commandId));
        executor.retryCommand(REMOTE_CHAIN);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandExpired.selector, commandId));
        executor.retryCommandWithBudget(REMOTE_CHAIN, 5_000_000);
        assertEq(uint8(_activeCommandStatus()), uint8(CommandStatus.FAILED), "state untouched by the refused retry");

        vm.prank(manager);
        executor.cancelCommand(REMOTE_CHAIN); // the exit is never refused
        assertTrue(_commandSlotActive(), "awaiting the EXPIRED receipt");

        // The deadline is inclusive: a fresh failed command can still be retried AT it.
        _relayAll();
        assertFalse(_commandSlotActive());
        burnVault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 c2, uint256 i2) = _sendDeposit(10e6);
        relayCursor = endpoint.sentCount();
        (ok,) = _deliver(i2, commandLaneGas);
        assertTrue(ok);
        _relayAll();
        vm.warp(CrosschainMessages.commandDeadline(c2));
        vm.prank(manager);
        executor.retryCommand(REMOTE_CHAIN);
    }

    // ---------------------------------------------------------------------
    // Constants relations
    // ---------------------------------------------------------------------

    function testShouldKeepTheGasConstantsConsistent() public pure {
        assertGe(CrosschainConstants.COMMAND_CATCH_RESERVE_GAS, CrosschainConstants.MIN_NACK_GAS, "reserve pays a NACK");
        assertLt(
            CrosschainConstants.COMMAND_CATCH_RESERVE_GAS,
            CrosschainConstants.COMMAND_EXECUTION_MIN_GAS,
            "budget >= floor > reserve: the capped self-call cannot underflow"
        );
        // A maximum-size UPDATE_VAULTS (32 vaults) is the largest Stargate payload: its inner encoding is
        // offset + 5 head words + length + one word per vault = 7 + MAX_ALLOWED_VAULTS words.
        uint256 maxWords = 7 + CrosschainConstants.MAX_ALLOWED_VAULTS;
        uint256 formulaMin = CrosschainMessages.laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, maxWords, true);
        // The cold-measured work of that payload on the real endpoint (`StargatePreCheckForkTest`, forge 1.8.5 cold semantics: up to
        // 1,331,535 gas net of the hop loss for 39 words, cold accounts included) must fit the minimum lane's allowance with the 100k cold margin.
        // Hardcoded on purpose (this test is pure); the fork test `StargatePreCheckForkTest` is the AUTHORITATIVE cold
        // check of the same margin and fails first if the figure drifts.
        uint256 coldWork32 = 1_331_535;
        assertGe(
            CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * maxWords,
            coldWork32 + 100_000,
            "the allowance of the largest payload covers its cold-measured work with 100k to spare"
        );
        assertGe(
            StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS,
            formulaMin,
            "the minimum registrable lane yields the floor budget for the largest UPDATE_VAULTS"
        );
        assertLe(
            StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS - formulaMin,
            100_000,
            "and is the formula minimum rounded up to the next 100k"
        );
        assertEq(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, 1_000_000);
    }

    /// @notice EIP-7825 (Fusaka) caps an Ethereum transaction at 2^24 gas: the lzReceive gas the largest payload needs to
    ///         reach `MAX_COMMAND_EXECUTION_GAS` (formula incl. the endpoint's lane / 64 term, Stargate; CCIP form without)
    ///         plus 1M of executor transaction overhead stays under it, on both transports.
    function testShouldKeepTheMaximumBudgetDeliverableUnderTheEthereumTransactionGasCap() public pure {
        uint256 cap = 16_777_216; // 2^24
        uint256 stargateMaxWords = 7 + CrosschainConstants.MAX_ALLOWED_VAULTS;
        uint256 ccipMaxWords = 3 + 7 + 1 + 3 + 1 + CrosschainConstants.MAX_ALLOWED_VAULTS;
        uint256 stargateDelivered =
            CrosschainMessages.laneGasFor(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS, stargateMaxWords, true);
        uint256 ccipDelivered =
            CrosschainMessages.laneGasFor(CrosschainConstants.MAX_COMMAND_EXECUTION_GAS, ccipMaxWords, false);
        assertLt(stargateDelivered + 1_000_000, cap, "Stargate: the maximum budget is deliverable in one Ethereum tx");
        assertLt(ccipDelivered + 1_000_000, cap, "CCIP: the maximum budget is deliverable in one Ethereum tx");
    }
}

contract CommandOutOfGasToken is ERC20 {
    constructor() ERC20("CCIP USDC", "cUSDC") {}

    function mint(address to_, uint256 amount_) external {
        _mint(to_, amount_);
    }
}

/// @title CcipCommandOutOfGasTest
/// @notice IL-8625, CCIP half: OffRamp execution / manual execution is permissionless, so the same budget rule holds for
///         the CCIP dispatcher's run and retry paths. The route policy (`messageGasLimit`) is the lane: 2,000,000 by
///         default. The real Router forwards exactly the message's gas limit, so deliveries here use
///         `MockCcipRouter.deliverHeldExact`.
contract CcipCommandOutOfGasTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant LANE_GAS = 2_000_000;
    uint256 internal constant CALL_MARGIN = 250_000;

    MockCcipRouter internal router;
    CommandOutOfGasToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockCcipRouteValidator internal routeValidator;
    MockGasBurnVault internal vault;
    uint256 internal lane = LANE_GAS;

    event CommandFailed(bytes32 commandId, uint64 sequence);

    function setUp() public {
        _deployAll(LANE_GAS);
    }

    function _deployAll(uint256 lane_) internal {
        lane = lane_;
        router = new MockCcipRouter();
        token = new CommandOutOfGasToken();
        routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router), factory, address(this), address(token), keccak256("USDC"), 18, _safety()
        );
        CcipRouteConfig memory back = _route(EXECUTOR_SELECTOR, address(executor), lane_);
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
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher), lane_);
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);

        vault = new MockGasBurnVault(token);
        _allowVault(address(vault), true);
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 0);
        _attestBalance(dispatcher.accountedBalance());
    }

    function _route(uint64 selector_, address peer_, uint256 gas_) internal pure returns (CcipRouteConfig memory) {
        return CcipRouteConfig({
            chainSelector: selector_,
            peer: peer_,
            feeToken: address(0),
            messageGasLimit: uint96(gas_),
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
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

    function _allowVault(address vault_, bool replace_) internal {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, replace_, 0, address(0), 0);
    }

    function _attestBalance(uint256 balance_) internal {
        vm.warp(block.timestamp + 1);
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

    function _command(uint8 action_, bytes memory actionData_, uint64 budget_) internal pure returns (Command memory) {
        return Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: action_,
            minExecutionGas: budget_,
            actionData: actionData_
        });
    }

    function _holdCommand(uint8 action_, bytes memory actionData_) internal returns (bytes32 commandId, uint256 held) {
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _command(action_, actionData_, 0), 0, address(0), 0);
        router.setAutoDeliver(true);
        commandId = executor.activeCommand(REMOTE_CHAIN);
        held = router.heldCount() - 1;
    }

    function _holdDeposit(address vault_, uint256 amount_) internal returns (bytes32 commandId, uint256 held) {
        return _holdCommand(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(vault_, amount_, 0));
    }

    function _holdRedeem(address vault_, uint256 shares_) internal returns (bytes32 commandId, uint256 held) {
        return _holdCommand(uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(vault_, shares_, 0));
    }

    /// @dev Delivers with EXACTLY `gas_` to the dispatcher, as the real Router does.
    function _deliver(uint256 held_, uint256 gas_) internal returns (bool ok, bytes memory ret) {
        (ok, ret) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held_, gas_)));
    }

    function _deliverAndRevert(uint256 held_, uint256 gas_) internal returns (bool ok, bytes memory ret) {
        uint256 snap = vm.snapshotState();
        (ok, ret) = _deliver(held_, gas_);
        vm.revertToState(snap);
    }

    function _storedCommand(uint256 held_) internal view returns (Command memory c, bytes memory inner) {
        (, inner) = CcipMessages.decode(router.heldData(held_));
        (, c,) = abi.decode(inner, (CcipMsgType, Command, bytes));
    }

    function _budgetOf(uint256 held_) internal view returns (uint256) {
        (Command memory c,) = _storedCommand(held_);
        return c.minExecutionGas;
    }

    /// @dev Smallest delivery gas at which the dispatcher reaches its budget check for the held message.
    function _threshold(uint256 held_) internal returns (uint256 hi) {
        uint256 lo = _budgetOf(held_);
        hi = lane + 1_000_000;
        (bool okHi,) = _deliverAndRevert(held_, hi);
        (bool okLo,) = _deliverAndRevert(held_, lo);
        assertTrue(okHi, "generous gas reaches the check");
        assertFalse(okLo, "the budget as total gas does not");
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            (bool ok,) = _deliverAndRevert(held_, mid);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    function _packPolicy(uint96 messageGas_) internal pure returns (uint256) {
        return uint256(messageGas_) | (uint256(2_000_000) << 96) | (1 << 192);
    }

    function _words(uint256 held_) internal view returns (uint256) {
        (, bytes memory inner) = _storedCommand(held_);
        return CrosschainMessages.payloadWords(inner.length);
    }

    // ---------------------------------------------------------------------
    // The budget is stamped from the effective route gas and the payload
    // ---------------------------------------------------------------------

    function testShouldStampTheBudgetOfCommandAndUpdateVaultsFromTheRoutePolicy() public {
        (, uint256 held) = _holdDeposit(address(vault), 10e18);
        (Command memory c,) = _storedCommand(held);
        assertEq(
            c.minExecutionGas,
            CrosschainMessages.commandGasBudget(LANE_GAS, _words(held), false),
            "COMMAND budget = formula(route gas, words)"
        );
        router.deliverHeld(held);

        router.setAutoDeliver(false);
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, true, 0, address(0), 0);
        router.setAutoDeliver(true);
        uint256 updateHeld = router.heldCount() - 1;
        (c,) = _storedCommand(updateHeld);
        assertEq(
            c.minExecutionGas,
            CrosschainMessages.commandGasBudget(LANE_GAS, _words(updateHeld), false),
            "UPDATE_VAULTS budget = formula(route gas, its own words)"
        );
    }

    /// @notice An override above the policy is clamped to it, so the budget never exceeds what the route delivers.
    function testShouldDeriveTheBudgetFromTheClampedOverride() public {
        (, uint256 plain) = _holdDeposit(address(vault), 10e18);
        uint256 expected = _budgetOf(plain);
        router.deliverHeld(plain);
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            _command(uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(address(vault), 10e18, 0), 0),
            0,
            address(0),
            LANE_GAS * 3
        );
        assertEq(_budgetOf(router.heldCount() - 1), expected, "clamped to the policy, not to the override");
    }

    function testShouldRefuseToSendWhenTheRouteGasIsTooSmallForThePayload() public {
        (, uint256 probe) = _holdDeposit(address(vault), 1e18);
        uint256 minLane = CrosschainMessages.laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, _words(probe), false);
        router.deliverHeld(probe);
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(minLane - 1)), 0);

        // The caller's own override cannot help: 0 and above-policy clamp to the policy, which is what decides.
        bytes memory deposit = CrosschainMessages.encodeDepositAction(address(vault), 1e18, 0);
        uint256[3] memory overrides = [uint256(0), minLane, LANE_GAS * 5];
        for (uint256 i; i < overrides.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneGasTooLow.selector, minLane - 1, minLane));
            executor.sendCommandToDispatcher(
                REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, 0), 0, address(0), overrides[i]
            );
        }

        // Exactly the minimum is accepted.
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(minLane)), 0);
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, 0), 0, address(0), 0
        );
        assertEq(_budgetOf(router.heldCount() - 1), CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, "floor budget");
        router.setAutoDeliver(true);
        router.deliverHeld(router.heldCount() - 1); // the command runs and its ACK frees the slot

        // UPDATE_VAULTS is a bigger payload: the same route is refused for it.
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(minLane - 1)), 0);
        address[] memory vaults = new address[](8);
        for (uint256 i; i < vaults.length; ++i) {
            vaults[i] = address(uint160(0x1000 + i));
        }
        vm.expectPartialRevert(CrosschainErrors.CommandLaneGasTooLow.selector);
        executor.updateVaults(REMOTE_CHAIN, vaults, true, true, 0, address(0), 0);
    }

    /// @notice CCIP does not ignore `Command.minExecutionGas`: non-zero must not exceed the derived budget (the route
    ///         policy is the only way to give more) and the cap; the derived budget is what is stamped.
    function testShouldRejectAManagerBudgetAboveTheDerivedBudgetOrTheCap() public {
        (, uint256 plain) = _holdDeposit(address(vault), 10e18);
        uint256 derived = _budgetOf(plain);
        router.deliverHeld(plain);
        bytes memory deposit = CrosschainMessages.encodeDepositAction(address(vault), 10e18, 0);

        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveLane.selector, derived + 1, derived));
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, uint64(derived + 1)), 0, address(0), 0
        );

        uint256 cap = CrosschainConstants.MAX_COMMAND_EXECUTION_GAS;
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveMax.selector, cap + 1, cap));
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, uint64(cap + 1)), 0, address(0), 0
        );

        // At or below the derived budget it is accepted, and the DERIVED budget is stamped.
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, uint64(derived - 1)), 0, address(0), 0
        );
        assertEq(_budgetOf(router.heldCount() - 1), derived, "the derived budget is stamped");
    }

    /// @notice A RETRY re-runs the STORED budget, so it is refused when the route policy was lowered below what the stored
    ///         budget needs since the original send (it would revert below the budget at every delivery).
    function testShouldRefuseARetryWhoseRouteGasCannotCoverTheStoredBudget() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        uint256 required = CrosschainMessages.laneGasFor(_budgetOf(held), _words(held), false);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED));

        uint256 lowered = required - 1;
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(lowered)), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.RetryGasBelowCommandBudget.selector, commandId, lowered, required
            )
        );
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);

        // Restoring the policy lets the retry go out, with the ORIGINAL budget.
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(LANE_GAS)), 0);
        vault.setMode(MockGasBurnVault.Mode.NORMAL);
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        (ok,) = _deliver(router.heldCount() - 1, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "retry ran");
    }

    // ---------------------------------------------------------------------
    // Below the budget: revert, retryable. At / above the budget: FAILED + NACK, out-of-gas included
    // ---------------------------------------------------------------------

    function testShouldRevertBelowTheBudgetAndStayRetryable() public {
        vault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 seqBefore = dispatcher.nextCommandSequence();
        uint64 tail = dispatcher.responseQueueTail();

        (bool ok, bytes memory ret) = _deliver(held, _budgetOf(held));

        assertFalse(ok, "below the budget the execution fails on the OffRamp");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector, "budget error");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "no status written");
        assertEq(dispatcher.nextCommandSequence(), seqBefore, "sequence untouched");
        assertEq(dispatcher.trackedIdle(), idleBefore, "no capital moved");
        assertEq(dispatcher.responseQueueTail(), tail, "no NACK queued");

        vault.setMode(MockGasBurnVault.Mode.NORMAL);
        (ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok, "manual execution with the lane gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "ran on retry");
    }

    function testShouldRecordFailedAndNackForAnOutOfGasActionAtTheBudget() public {
        vault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(commandId, dispatcher.nextCommandSequence());
        (bool ok,) = _deliver(held, LANE_GAS);

        assertTrue(ok, "at the budget an out-of-gas action is a clean execution");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK reached the executor");
    }

    function testShouldRecordFailedAndNackForAnOutOfGasActionAtTheThreshold() public {
        vault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        uint256 threshold = _threshold(held);

        (bool ok,) = _deliver(held, threshold);

        assertTrue(ok, "at the threshold an out-of-gas action is a clean execution");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK reached the executor");
    }

    function testShouldPlaceTheDeliveryThresholdBetweenTheBudgetAndTheRouteGas() public {
        (, uint256 held) = _holdDeposit(address(vault), 10e18);
        uint256 budget = _budgetOf(held);
        uint256 threshold = _threshold(held);
        (bool okLane,) = _deliverAndRevert(held, LANE_GAS);
        (bool okBelow, bytes memory ret) = _deliverAndRevert(held, threshold - 1);
        assertTrue(okLane, "the route gas reaches the check");
        assertFalse(okBelow);
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        emit log_named_uint("CCIP DEPOSIT threshold delivery gas:", threshold);
        emit log_named_uint("CCIP DEPOSIT pre-call work (threshold - budget):", threshold - budget);
        emit log_named_uint("CCIP DEPOSIT allowance (route gas - budget):", LANE_GAS - budget);
        assertGt(threshold, budget, "the dispatcher spends gas before the check");
        assertLe(threshold, LANE_GAS, "pre-call work is covered by the route gas");
    }

    function testShouldStillPersistFailedAndNackForADecodableBusinessError() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(commandId, dispatcher.nextCommandSequence());
        (bool ok,) = _deliver(held, LANE_GAS);

        assertTrue(ok, "business failure is a clean execution");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
    }

    /// @dev The RETRY site (`_retryCommand`): a FAILED command re-run under the STORED budget. Below it the retry reverts
    ///      and the FAILED record survives; at the route gas an out-of-gas retry is FAILED again (re-armed NACK).
    function testShouldHoldARetryToTheStoredBudget() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        uint256 budget = _budgetOf(held);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED));

        vault.setMode(MockGasBurnVault.Mode.BURN_DEEP);
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        router.setAutoDeliver(true);
        uint256 retryHeld = router.heldCount() - 1;

        bytes memory ret;
        (ok, ret) = _deliver(retryHeld, budget);
        assertFalse(ok, "a retry below the stored budget reverts");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "still FAILED, not PENDING");

        (ok,) = _deliver(retryHeld, LANE_GAS);
        assertTrue(ok, "an out-of-gas retry at the budget is a business failure");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED again");

        vault.setMode(MockGasBurnVault.Mode.NORMAL);
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        router.setAutoDeliver(true);
        (ok,) = _deliver(router.heldCount() - 1, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "retry succeeded");
    }

    function testShouldTreatWrappedOutOfGasAndVaultReadGasErrorsAsBusinessFailuresAtTheBudget() public {
        MockGasBurnVault.Mode[3] memory modes = [
            MockGasBurnVault.Mode.OZ_FAILED_INNER_CALL,
            MockGasBurnVault.Mode.OZ_FAILED_CALL,
            MockGasBurnVault.Mode.VAULT_READ_GAS_ERROR
        ];
        for (uint256 i; i < modes.length; ++i) {
            uint256 snap = vm.snapshotState();
            vault.setMode(modes[i]);
            (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);

            (bool ok,) = _deliver(held, LANE_GAS);

            assertTrue(ok, "clean execution at the budget");
            assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
            vm.revertToState(snap);
        }
    }

    function testShouldPersistFailedAndNackWhenACalleeBurnsAllItsGasThenRevertsWithASelector() public {
        vault.setMode(MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);

        (bool ok,) = _deliver(held, LANE_GAS);

        assertTrue(ok, "the reserve lets the catch frame finish");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
    }

    function testShouldPersistFailedWhenARetryBurnsAllItsGasThenRevertsWithASelector() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);

        vault.setMode(MockGasBurnVault.Mode.BURN_ALL_THEN_BUSINESS_ERROR);
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        router.setAutoDeliver(true);
        (ok,) = _deliver(router.heldCount() - 1, LANE_GAS);

        assertTrue(ok, "the reserve lets the retry's catch frame finish");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED again");
    }

    function testShouldNotLetALargeRevertPayloadEatTheReserve() public {
        vault.setMode(MockGasBurnVault.Mode.BIG_PAYLOAD_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);

        (bool ok,) = _deliver(held, LANE_GAS);

        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
    }

    function testShouldMeasureTheWholeFailedDeliveryGas() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (, uint256 held) = _holdDeposit(address(vault), 10e18);
        uint256 g0 = gasleft();
        (bool ok,) = _deliver(held, LANE_GAS);
        uint256 used = g0 - gasleft();
        assertTrue(ok);
        emit log_named_uint("CCIP whole FAILED + NACK delivery gas (business revert, mocks):", used);
        assertLt(used, CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, "a plain failure fits the budget");
    }

    // ---------------------------------------------------------------------
    // Budget binding
    // ---------------------------------------------------------------------

    /// @notice The budget is inside the committed bytes: the dispatcher's stored commitment is the hash of the data that
    ///         carries `minExecutionGas`, and a lowered budget hashes differently, so neither a replay nor a RETRY can
    ///         run a command under another budget.
    function testShouldBindTheBudgetIntoTheCommitment() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 50e18);
        (Command memory c, bytes memory inner) = _storedCommand(held);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);

        assertEq(c.minExecutionGas, _budgetOf(held));
        assertEq(dispatcher.commandCommitment(commandId), keccak256(inner), "committed bytes carry the budget");
        c.minExecutionGas = uint64(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS);
        bytes memory lowered = abi.encode(CcipMsgType.COMMAND, c, bytes(""));
        assertTrue(keccak256(lowered) != dispatcher.commandCommitment(commandId), "a lowered budget is another commitment");

        // The same message cannot be run again as a fresh command either.
        vm.expectRevert(abi.encodeWithSignature("CcipMessageAlreadyProcessed(bytes32)", commandId));
        _redeliverAs(lowered);
    }

    function _redeliverAs(bytes memory inner_) internal {
        // Authenticated as the router would: `ccipReceive` from the router with the executor as sender.
        bytes memory payload = CcipMessages.encode(CcipMsgType.COMMAND, inner_);
        vm.prank(address(router));
        dispatcher.ccipReceive(
            CcipClient.Any2EVMMessage({
                messageId: keccak256("replayed"),
                sourceChainSelector: EXECUTOR_SELECTOR,
                sender: abi.encode(address(executor)),
                data: payload,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            })
        );
    }

    // ---------------------------------------------------------------------
    // R1: a REDEEM above the vault's instant liquidity on a WETH9- / USDT-shaped token
    // ---------------------------------------------------------------------

    function _r1(ShapedTokenBase liquidityToken_) internal {
        MockShapedLiquidityVault shaped =
            new MockShapedLiquidityVault(IERC20(address(token)), IERC20(address(liquidityToken_)));
        _allowVault(address(shaped), false);
        liquidityToken_.mint(address(shaped), 20e18); // instant liquidity
        (bytes32 opened, uint256 openHeld) = _holdDeposit(address(shaped), 50e18);
        (bool ok,) = _deliver(openHeld, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(opened)), uint8(CommandStatus.SUCCEEDED));
        assertEq(shaped.balanceOf(address(dispatcher)), 50e18, "position opened");

        // 50e18 shares above the 20e18 of instant liquidity: the token reverts with EMPTY data, SafeERC20 wraps it.
        (bytes32 commandId, uint256 held) = _holdRedeem(address(shaped), 50e18);
        (ok,) = _deliver(held, LANE_GAS);

        assertTrue(ok, "the execution no longer fails at any gas: it is a business failure at the budget");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK reached the executor");

        // The manager frees the lane in the same block and sends a smaller REDEEM that succeeds.
        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "lane freed in the same block");
        (bytes32 smaller, uint256 smallerHeld) = _holdRedeem(address(shaped), 20e18);
        (ok,) = _deliver(smallerHeld, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(smaller)), uint8(CommandStatus.SUCCEEDED), "smaller REDEEM succeeded");
        assertEq(shaped.balanceOf(address(dispatcher)), 30e18, "20e18 shares redeemed");
    }

    function testShouldNackARedeemAboveInstantLiquidityOnAWeth9ShapedToken() public {
        _r1(ShapedTokenBase(address(new Weth9ShapedToken())));
    }

    function testShouldNackARedeemAboveInstantLiquidityOnAUsdtShapedToken() public {
        _r1(ShapedTokenBase(address(new UsdtShapedToken())));
    }

    // ---------------------------------------------------------------------
    // R5: an out-of-gas inside the AccessManager check surfaces as a decodable AccessManagedUnauthorized
    // ---------------------------------------------------------------------

    function _gatedPosition() internal returns (MockAuthorityGatedVault gated) {
        gated = new MockAuthorityGatedVault(IERC20(address(token)));
        _allowVault(address(gated), false);
        (bytes32 opened, uint256 held) = _holdDeposit(address(gated), 50e18);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(opened)), uint8(CommandStatus.SUCCEEDED));
    }

    function testShouldNeverCommitAnAccessManagerOutOfGasBelowTheBudget() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(400_000);
        (bytes32 commandId, uint256 held) = _holdRedeem(address(gated), 50e18);
        uint64 tail = dispatcher.responseQueueTail();

        (bool ok, bytes memory ret) = _deliver(held, _budgetOf(held));
        assertFalse(ok, "reverts instead of recording a forged refusal");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "no status written");
        assertEq(dispatcher.responseQueueTail(), tail, "no NACK");

        (ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok, "at the budget on a correctly sized lane it succeeds");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "REDEEM succeeded");
        assertEq(gated.balanceOf(address(dispatcher)), 0);
    }

    /// @notice The attacker's best gas: the exact threshold. Sized check: SUCCEEDED; check needing slightly more than the
    ///         call gets: FAILED + NACK (the lane must be sized to the measured check).
    function testShouldSucceedAtTheThresholdWhenTheLaneIsSizedAndNackWhenItIsNot() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        (bytes32 commandId, uint256 held) = _holdRedeem(address(gated), 50e18);
        uint256 budget = _budgetOf(held);
        uint256 threshold = _threshold(held);
        uint256 callGas = budget - CrosschainConstants.COMMAND_CATCH_RESERVE_GAS;

        uint256 snap = vm.snapshotState();
        gated.AUTHORITY().setGasNeeded(callGas - CALL_MARGIN);
        (bool ok,) = _deliver(held, threshold);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "sized lane: REDEEM succeeded");
        vm.revertToState(snap);

        gated.AUTHORITY().setGasNeeded(callGas + 100_000);
        (ok,) = _deliver(held, threshold);
        assertTrue(ok, "delivered at the threshold");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "undersized lane: NACK");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK reached the executor");
    }

    /// @notice CCIP recovery of an undersized route: the retry's gas limit is clamped to the route policy and a NACKed
    ///         retry is a SUCCESSFUL OffRamp execution (no override), so the way to give a retry more gas is a (timelocked)
    ///         route-policy raise before it. The retry re-runs the stored budget; the real Router forwards exactly the
    ///         new policy, which the call then gets.
    function testShouldNackATightRouteAndRecoverWithAPolicyRaiseThenARetry() public {
        MockAuthorityGatedVault gated = _gatedPosition();
        gated.AUTHORITY().setGasNeeded(2_000_000);
        (bytes32 commandId, uint256 held) = _holdRedeem(address(gated), 50e18);

        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok, "delivered at the route gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK: the route is too small");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED));

        // A retry at the SAME policy fails the same way: the retry's limit is the policy.
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        (ok,) = _deliver(router.heldCount() - 1, LANE_GAS);
        assertTrue(ok, "a NACKed retry is a successful execution on the OffRamp");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "still FAILED");
        router.setAutoDeliver(true);
        router.deliverHeld(router.heldCount() - 1); // the NACK the retry produced reaches the executor
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "executor re-armed to FAILED");

        // Raise the route policy (timelocked in production), then retry: the router forwards exactly the new policy.
        uint256 raised = 8_000_000;
        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(raised)), 0);
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        (ok,) = _deliver(router.heldCount() - 1, raised);
        assertTrue(ok);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.SUCCEEDED), "recovered on the raised policy");
        assertEq(gated.balanceOf(address(dispatcher)), 0);
    }

    /// @notice Expiry before budget on CCIP: before the deadline (and at it) a below-budget delivery fails on the OffRamp; one
    ///         second past it an execution with enough gas to send the NACK records FAILED + NACK without a business call, and the
    ///         manager's CANCEL gets the `EXPIRED` receipt that frees the lane, no admin, sequence not consumed.
    function testShouldNackAnExpiredCommandBelowItsBudgetAndFreeTheLaneWithoutTheAdmin() public {
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 10e18);
        uint64 seq = dispatcher.nextCommandSequence();
        uint256 deadline = CrosschainMessages.commandDeadline(commandId);
        uint256 lowGas = 900_000; // below the ~1.2M budget, above the pre-check work and the NACK guard

        (bool ok, bytes memory ret) = _deliver(held, lowGas);
        assertFalse(ok, "not expired: below the budget fails");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);
        vm.warp(deadline);
        (ok, ret) = _deliver(held, lowGas);
        assertFalse(ok, "at the deadline (inclusive) the budget check still applies");
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForCommand.selector);

        vm.warp(deadline + 1);
        (ok,) = _deliver(held, lowGas);
        assertTrue(ok, "an expired command is recorded at low gas");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED persisted");
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK reached the executor");
        assertEq(dispatcher.nextCommandSequence(), seq, "sequence not consumed");

        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "lane freed by the manager, no ABANDON");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "closed by the expired cancel");
        assertEq(dispatcher.nextCommandSequence(), seq, "the expired cancel does not consume the sequence");
        assertEq(executor.nextCommandSequence(REMOTE_CHAIN), seq, "mirror unchanged: the next command reuses it");
    }

    /// @notice An expired command is still subject to the NACK guard.
    function testShouldStillGuardTheNackGasOfAnExpiredCommand() public {
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 10e18);
        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        (bool ok, bytes memory ret) = _deliver(held, 450_000);
        assertFalse(ok);
        assertEq(bytes4(ret), CrosschainErrors.InsufficientGasForNack.selector);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.NONE), "nothing stored");
    }

    /// @notice `_retryCommand` delivered after the deadline below its budget is FAILED + NACK (sent in time, delivered late).
    function testShouldNackARetryDeliveredAfterTheDeadlineBelowItsBudget() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 10e18);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED));
        uint64 seq = dispatcher.nextCommandSequence();

        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        uint256 retryHeld = router.heldCount() - 1;
        vm.warp(CrosschainMessages.commandDeadline(commandId) + 1);
        (ok,) = _deliver(retryHeld, 900_000);
        assertTrue(ok, "the late retry is recorded at low gas, below its budget");
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "FAILED again");
        router.setAutoDeliver(true);
        router.deliverHeld(router.heldCount() - 1); // the NACK reaches the executor
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED));

        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "lane freed by the manager");
        assertEq(dispatcher.nextCommandSequence(), seq, "sequence not consumed");
    }

    /// @notice The executor refuses a RETRY past the deadline; at the deadline (inclusive) it is allowed; CANCEL is never refused.
    function testShouldRefuseARetryOfACommandPastItsDeadline() public {
        vault.setMode(MockGasBurnVault.Mode.BUSINESS_ERROR);
        (bytes32 commandId, uint256 held) = _holdDeposit(address(vault), 10e18);
        (bool ok,) = _deliver(held, LANE_GAS);
        assertTrue(ok);
        uint256 deadline = CrosschainMessages.commandDeadline(commandId);

        vm.warp(deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandExpired.selector, commandId));
        executor.retryCommand(REMOTE_CHAIN, commandId, 0, address(0), 0);
        executor.cancelCommand(REMOTE_CHAIN, commandId, 0, address(0), 0); // never refused
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0));

        (bytes32 c2, uint256 h2) = _holdDeposit(address(vault), 10e18);
        (ok,) = _deliver(h2, LANE_GAS);
        assertTrue(ok);
        vm.warp(CrosschainMessages.commandDeadline(c2));
        router.setAutoDeliver(false);
        executor.retryCommand(REMOTE_CHAIN, c2, 0, address(0), 0); // inclusive deadline: still allowed
    }

    /// @notice The STAMPED budget is bounded by `MAX_COMMAND_EXECUTION_GAS` too: a route policy that would derive more is
    ///         refused, exactly the cap is accepted.
    function testShouldBoundTheStampedBudgetByTheCap() public {
        (, uint256 probe) = _holdDeposit(address(vault), 1e18);
        uint256 words = _words(probe);
        router.deliverHeld(probe);
        uint256 cap = CrosschainConstants.MAX_COMMAND_EXECUTION_GAS;
        uint256 atCap = CrosschainMessages.laneGasFor(cap, words, false);
        bytes memory deposit = CrosschainMessages.encodeDepositAction(address(vault), 1e18, 0);

        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(atCap + 1)), 0);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandBudgetAboveMax.selector, cap + 1, cap));
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, 0), 0, address(0), 0
        );

        vm.prank(address(routeValidator));
        executor.syncRoutePolicy(REMOTE_CHAIN, address(0), _packPolicy(uint96(atCap)), 0);
        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN, _command(uint8(BusinessAction.DEPOSIT), deposit, 0), 0, address(0), 0
        );
        assertEq(_budgetOf(router.heldCount() - 1), cap, "exactly the cap is stamped");
    }

    function testShouldKeepTheCcipVersionPinnedForTheNewCommandLayout() public pure {
        assertEq(CcipMessages.VERSION, 3, "an old dispatcher must reject the new Command layout");
    }
}
