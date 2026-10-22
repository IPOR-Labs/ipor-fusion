// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateTwoSidedBase} from "./StargateTwoSidedBase.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CommandStatus, CrosschainConstants, MsgType} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateExecutorDeploymentLib} from "../../contracts/crosschain/stargate/lib/StargateExecutorDeploymentLib.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {CommandOutOfGasToken} from "./CommandOutOfGasTest.t.sol";
import {ColdGas} from "./ColdGas.sol";

/// @title StargatePreCheckPinTest
/// @notice IL-8625 calibration pins of `COMMAND_PRE_CALL_BASE` / `COMMAND_PRE_CALL_PER_WORD` on the Stargate dispatcher
///         (mock endpoint, every slot re-cooled before each trial). For a DEPOSIT and an UPDATE_VAULTS of 0 / 8 / 16 / 32 vaults, on lanes of the
///         minimum registrable gas, 4M and 10M: the delivery at EXACTLY the lane's gas reaches the budget check and the
///         measured pre-check work (smallest passing delivery gas minus the budget) is within the formula's allowance.
///         The real endpoint's lane/64 hop loss is pinned by `StargatePreCheckForkTest`.
contract StargatePreCheckPinTest is StargateTwoSidedBase, ColdGas {
    using OptionsBuilder for bytes;

    uint256 internal constant MIN_LANE = StargateExecutorDeploymentLib.COMMAND_LANE_MIN_RECEIVE_GAS;

    MockRemoteVault[] internal vaults;

    function _setUpLane(uint128 lane_) internal {
        commandLaneGas = lane_;
        _twoSidedSetUp();
        _bringUpBothSides();
        for (uint256 i; i < 32; ++i) {
            vaults.push(new MockRemoteVault(IERC20(address(usdc)), "V", "V"));
        }
        remoteVault = vaults[0];
        _allowRemoteVault();
        _bridgeToDispatcher(100e6);
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

    /// @return budget The stamped budget; words The stored words.
    function _stamped(uint256 index_) internal view returns (uint256 budget, uint256 words) {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(index_);
        (MsgType t, bytes memory data) = CrosschainMessages.decodeEnvelope(m.message);
        words = CrosschainMessages.payloadWords(data.length);
        budget = t == MsgType.COMMAND
            ? CrosschainMessages.decodeCommand(data).minExecutionGas
            : CrosschainMessages.decodeUpdateVaults(data).minExecutionGas;
    }

    function _check(string memory label_, uint256 index_, bytes32 commandId_, uint256 lane_)
        internal
        returns (CommandStatus statusAtLane)
    {
        uint256 snap = vm.snapshotState();
        (bool ok,) = _deliver(index_, lane_);
        assertTrue(ok, string.concat(label_, ": delivery at the lane gas"));
        statusAtLane = dispatcher.commandStatus(commandId_);
        assertTrue(statusAtLane != CommandStatus.NONE, string.concat(label_, ": reached the budget check"));
        vm.revertToState(snap);
        _assertMargin(label_, index_, lane_);
    }

    function _assertMargin(string memory label_, uint256 index_, uint256 lane_) internal {
        (uint256 budget, uint256 words) = _stamped(index_);
        // Measured pre-check work: the smallest gas that still reaches the check, minus the budget it compares with,
        // with every slot of every account the delivery touches cooled before each trial (`ColdGas`).
        uint256 rec = vm.snapshotState();
        _beginRecording();
        _deliver(index_, lane_);
        address[] memory touched = _endRecording();
        vm.revertToState(rec);
        uint256 lo = budget;
        uint256 hi = lane_;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 s = vm.snapshotState();
            _cool(touched);
            (bool okMid,) = _deliver(index_, mid);
            vm.revertToState(s);
            if (okMid) hi = mid;
            else lo = mid;
        }
        // The mock endpoint -> OApp call loses 1/64 like the real hop; net of it this is the dispatcher's own work.
        uint256 pre = hi - budget - hi / 64 + _coldAccountPenalty(touched);
        uint256 allowance =
            CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * words;
        emit log_named_string("PIN", label_);
        emit log_named_uint("  lane", lane_);
        emit log_named_uint("  budget", budget);
        emit log_named_uint("  words", words);
        emit log_named_uint("  measured pre-check work (cooled, net of lane/64, cold accounts added)", pre);
        emit log_named_uint("  formula allowance (BASE + PER_WORD * words)", allowance);
        assertGe(allowance, pre + 100_000, string.concat(label_, ": the formula covers the cooled pre-check work by 100k"));
    }

    function _sendUpdate(uint256 n_) internal returns (bytes32 commandId, uint256 index) {
        address[] memory list = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            list[i] = address(vaults[i]);
        }
        vm.prank(manager);
        try executor.updatePlasmaVaults(REMOTE_CHAIN, list) {}
        catch (bytes memory r) {
            assertEq(bytes4(r), CrosschainErrors.CommandLaneGasTooLow.selector, "only the lane-size refusal");
            return (bytes32(0), type(uint256).max);
        }
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        index = _lastSentIndex();
    }

    function _runLane(uint128 lane_) internal {
        _setUpLane(lane_);
        // DEPOSIT
        vm.prank(manager);
        executor.sendCommandToDispatcher(REMOTE_CHAIN, _depositCommand(10e6));
        (,,,, bytes32 commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        _check("DEPOSIT", _lastSentIndex(), commandId, lane_);
        relayCursor = _lastSentIndex(); // run it for real so the slot frees
        _relayAll();
        assertFalse(_commandSlotActive(), "slot free after the deposit");

        uint256[4] memory sizes = [uint256(0), 8, 16, 32];
        for (uint256 i; i < sizes.length; ++i) {
            (bytes32 id, uint256 index) = _sendUpdate(sizes[i]);
            string memory label = string.concat("UPDATE_VAULTS ", vm.toString(sizes[i]));
            if (index == type(uint256).max) {
                emit log_named_string("refused (lane too small for the payload)", label);
                continue;
            }
            CommandStatus atLane = _check(label, index, id, lane_);
            // On a 4M lane the largest fresh install also EXECUTES at the lane's gas (the 2.81M of the README's table
            // includes the pre-check work); on the minimum lane it only reaches the check and NACKs, the sizing residual.
            if (lane_ >= 4_000_000 && sizes[i] == 32) {
                assertEq(uint8(atLane), uint8(CommandStatus.SUCCEEDED), "32-vault UPDATE_VAULTS executes on a 4M lane");
            }
            // Complete it so the next size can be sent (a real delivery with ample gas).
            relayCursor = index;
            _relayAll();
            assertFalse(_commandSlotActive(), "slot freed");
        }
    }

    function testShouldReachTheCheckAtTheMinimumRegistrableLane() public {
        _runLane(uint128(MIN_LANE));
    }

    function testShouldReachTheCheckOnA4MLane() public {
        _runLane(4_000_000);
    }

    function testShouldReachTheCheckOnA10MLane() public {
        _runLane(10_000_000);
    }

    /// @notice 2M is below the minimum registrable lane: the largest UPDATE_VAULTS could never get a floor budget there.
    function testShouldRefuseA2MLaneAtRegistration() public {
        _baseSetUp();
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: REMOTE_EID, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.CommandLaneOptionsInvalid.selector, REMOTE_EID));
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, abi.encode(options));
    }
}

/// @title CcipPreCheckPinTest
/// @notice IL-8625 calibration pins on the CCIP dispatcher. The real Router forwards exactly the message's gas limit to
///         `ccipReceive`, so the mock delivers with `deliverHeldExact` (no hop loss, no `lane / 64` term). For a DEPOSIT and
///         an UPDATE_VAULTS of 0 / 8 / 16 / 32 vaults, on route gas of 2M, 4M and 10M: either the executor refuses to send
///         (`CommandLaneGasTooLow`, the payload needs a bigger route) or the delivery at EXACTLY the route gas reaches the
///         budget check, and the measured pre-check work is within the formula's allowance.
contract CcipPreCheckPinTest is ColdGas {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);

    MockCcipRouter internal router;
    CommandOutOfGasToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockRemoteVault[] internal vaults;

    function _setUpLane(uint256 lane_) internal {
        router = new MockCcipRouter();
        token = new CommandOutOfGasToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: ADMIN,
                rescueGuardian: GUARDIAN,
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
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
            3 days
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
        for (uint256 i; i < 32; ++i) {
            vaults.push(new MockRemoteVault(IERC20(address(token)), "V", "V"));
        }
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

    function _deliver(uint256 held_, uint256 gas_) internal returns (bool ok) {
        (ok,) = address(router).call(abi.encodeCall(MockCcipRouter.deliverHeldExact, (held_, gas_)));
    }

    function _check(string memory label_, uint256 held_, bytes32 id_, uint256 lane_) internal {
        (, bytes memory inner) = CcipMessages.decode(router.heldData(held_));
        (, Command memory c,) = abi.decode(inner, (CcipMsgType, Command, bytes));
        uint256 snap = vm.snapshotState();
        assertTrue(_deliver(held_, lane_), string.concat(label_, ": delivery at the route gas"));
        assertTrue(dispatcher.commandStatus(id_) != CommandStatus.NONE, string.concat(label_, ": reached the check"));
        vm.revertToState(snap);
        _assertMargin(label_, held_, lane_, c.minExecutionGas, CrosschainMessages.payloadWords(inner.length));
    }

    function _assertMargin(string memory label_, uint256 held_, uint256 lane_, uint256 budget, uint256 words) internal {
        uint256 rec = vm.snapshotState();
        _beginRecording();
        _deliver(held_, lane_);
        address[] memory touched = _endRecording();
        vm.revertToState(rec);
        uint256 lo = budget;
        uint256 hi = lane_;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 s = vm.snapshotState();
            _cool(touched);
            bool ok = _deliver(held_, mid);
            vm.revertToState(s);
            if (ok) hi = mid;
            else lo = mid;
        }
        uint256 pre = hi - budget + _coldAccountPenalty(touched);
        uint256 allowance =
            CrosschainConstants.COMMAND_PRE_CALL_BASE + CrosschainConstants.COMMAND_PRE_CALL_PER_WORD * words;
        emit log_named_string("PIN", label_);
        emit log_named_uint("  route gas", lane_);
        emit log_named_uint("  budget", budget);
        emit log_named_uint("  words", words);
        emit log_named_uint("  measured pre-check work (cooled, cold accounts added)", pre);
        emit log_named_uint("  formula allowance (BASE + PER_WORD * words)", allowance);
        assertGe(allowance, pre + 100_000, string.concat(label_, ": the formula covers the cooled pre-check work by 100k"));
    }

    function _runLane(uint256 lane_) internal {
        _setUpLane(lane_);
        router.setAutoDeliver(false);

        // DEPOSIT (the vault only needs to be named; the check does not depend on the business outcome)
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.DEPOSIT),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeDepositAction(address(vaults[0]), 1e18, 0)
            }),
            0,
            address(0),
            0
        );
        _check("DEPOSIT", router.heldCount() - 1, executor.activeCommand(REMOTE_CHAIN), lane_);
        _runForReal();

        uint256[4] memory sizes = [uint256(0), 8, 16, 32];
        for (uint256 i; i < sizes.length; ++i) {
            address[] memory list = new address[](sizes[i]);
            for (uint256 j; j < sizes[i]; ++j) {
                list[j] = address(vaults[j]);
            }
            string memory label = string.concat("UPDATE_VAULTS ", vm.toString(sizes[i]));
            try executor.updateVaults(REMOTE_CHAIN, list, true, true, 0, address(0), 0) {}
            catch (bytes memory r) {
                assertEq(bytes4(r), CrosschainErrors.CommandLaneGasTooLow.selector, "only the route-size refusal");
                emit log_named_string("refused (route gas too small for the payload)", label);
                continue;
            }
            _check(label, router.heldCount() - 1, executor.activeCommand(REMOTE_CHAIN), lane_);
            _runForReal();
            assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot freed");
        }
    }

    /// @dev Executes the held message with ample gas and frees the command slot (a NACKed command is cancelled).
    function _runForReal() internal {
        router.setAutoDeliver(true);
        router.deliverHeld(router.heldCount() - 1);
        bytes32 active = executor.activeCommand(REMOTE_CHAIN);
        if (active != bytes32(0)) executor.cancelCommand(REMOTE_CHAIN, active, 0, address(0), 0);
        router.setAutoDeliver(false);
    }

    function testShouldReachTheCheckOnA2MRoute() public {
        _runLane(2_000_000);
    }

    function testShouldReachTheCheckOnA4MRoute() public {
        _runLane(4_000_000);
    }

    function testShouldReachTheCheckOnA10MRoute() public {
        _runLane(10_000_000);
    }

    /// @notice The 32-vault UPDATE_VAULTS still yields the floor budget on the documented route minimum.
    function testShouldSendAThirtyTwoVaultUpdateOnTheDocumentedRouteMinimum() public {
        // payload: (type, command, extra) with 32 vaults
        uint256 minRoute = _documentedRouteMinimum();
        _setUpLane(minRoute);
        address[] memory list = new address[](32);
        for (uint256 j; j < 32; ++j) {
            list[j] = address(vaults[j]);
        }
        router.setAutoDeliver(false);
        executor.updateVaults(REMOTE_CHAIN, list, true, true, 0, address(0), 0);
        (, bytes memory inner) = CcipMessages.decode(router.heldData(router.heldCount() - 1));
        (, Command memory c,) = abi.decode(inner, (CcipMsgType, Command, bytes));
        assertGe(c.minExecutionGas, CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, "floor budget at the minimum route");
        // one unit less is refused
        _setUpLane(minRoute - 1);
        router.setAutoDeliver(false);
        vm.expectPartialRevert(CrosschainErrors.CommandLaneGasTooLow.selector);
        executor.updateVaults(REMOTE_CHAIN, list, true, true, 0, address(0), 0);
    }

    /// @dev `laneGasFor(floor, words of the maximum UPDATE_VAULTS, no 1/64)`: the CCIP stored data is
    ///      `(type, command, extra)` = 3 head words + 7 command words + 1 + (3 head + 1 length + 32 vaults) extra words.
    function _documentedRouteMinimum() internal pure returns (uint256) {
        uint256 words = 3 + 7 + 1 + 3 + 1 + CrosschainConstants.MAX_ALLOWED_VAULTS;
        return CrosschainMessages.laneGasFor(CrosschainConstants.COMMAND_EXECUTION_MIN_GAS, words, false);
    }
}
