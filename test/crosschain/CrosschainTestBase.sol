// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {ExecutorInitParams} from "../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {
    CommandStatus,
    CommandResolution,
    MsgType,
    ReturnRejectReason
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    CommandAck,
    CommandNack,
    TransferSettled,
    ReturnStarted,
    ReturnRejected,
    OutboundTransfer
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockCrosschainFactory} from "./mocks/MockCrosschainFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

/// @title CrosschainTestBase
/// @notice Shared scaffolding for the executor-centric suites. Wires a real `StargateCrosschainExecutor` to a
///         controllable `MockCrosschainFactory` (the real factory cannot deploy a same-address dispatcher
///         on one EVM), a `MockLzEndpoint` and a `MockStargatePool`, and provides helpers to bring the
///         executor to a "dispatcher ready" state and to deliver crafted inbound receipts/composes.
abstract contract CrosschainTestBase is Test {
    using OptionsBuilder for bytes;

    /// @dev IL-8646: remote observation time committed by the last `_markFsObs()` Stargate force-set schedule.
    uint64 internal fsObs;

    /// @dev Records and returns "observed now" for a force-set schedule; execute passes `fsObs` back.
    function _markFsObs() internal returns (uint64) {
        fsObs = uint64(block.timestamp);
        return fsObs;
    }

    // Actors
    address internal manager = address(0x1111);
    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);
    address internal proposer = address(0xB0B0B0);
    address internal approver = address(0xB1B1B1);

    // Chain topology
    uint256 internal constant LOCAL_CHAIN = 1;
    uint256 internal constant REMOTE_CHAIN = 42161;
    uint32 internal constant LOCAL_EID = 30101;
    uint32 internal constant REMOTE_EID = 30110;
    bytes32 internal constant ASSET_ID = keccak256("USDC");

    // Executor params
    uint256 internal constant RESCUE_DELAY = 3 days;
    uint256 internal constant STALENESS_MAX = 1 hours;
    uint256 internal constant BIG_CHANGE_BPS = 1000; // 10%
    uint256 internal constant MIN_UPDATE_INTERVAL = 10 minutes;
    uint256 internal constant DEPLOYMENT_TTL = 1 days;
    uint256 internal constant TRANSFER_STALENESS_MAX = 2 hours;

    // Event topics (for log capture)
    bytes32 internal constant ASSET_SENT_TOPIC = keccak256("AssetSentToDispatcher(uint256,bytes32,bytes32,uint256)");
    bytes32 internal constant RETURN_REQUESTED_TOPIC = keccak256("ReturnRequested(uint256,bytes32,uint256,uint256)");

    /// @dev The command-lane `lzReceive` gas `_commandLaneOptions` registers (IL-8625: the minimum registrable lane is
    ///      2.5M = `COMMAND_LANE_MIN_RECEIVE_GAS`, so the default is 3M); pin tests set it before bring-up.
    uint128 internal commandLaneGas = 3_000_000;

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockCrosschainFactory internal factory;
    StargateCrosschainExecutor internal executor;

    function _baseSetUp() internal {
        vm.chainId(LOCAL_CHAIN);
        vm.warp(365 days); // non-trivial timestamp so staleness math never underflows

        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        factory = new MockCrosschainFactory();
        factory.setPath(REMOTE_CHAIN, REMOTE_EID);

        executor = _deployExecutor(address(factory), _params());
        vm.deal(address(executor), 100 ether);
        vm.label(address(executor), "StargateCrosschainExecutor");
    }

    function _params() internal view returns (ExecutorInitParams memory) {
        return ExecutorInitParams({
            assetId: ASSET_ID,
            manager: manager,
            admin: admin,
            rescueGuardian: guardian,
            rescueDelay: RESCUE_DELAY,
            balanceProposer: proposer,
            balanceApprover: approver,
            stalenessMax: STALENESS_MAX,
            bigChangeBps: BIG_CHANGE_BPS,
            minUpdateInterval: MIN_UPDATE_INTERVAL,
            deploymentTtl: DEPLOYMENT_TTL,
            transferStalenessMax: TRANSFER_STALENESS_MAX
        });
    }

    /// @dev Deploy the (oversized) executor from its compiled artifact so the test contract's own bytecode
    ///      stays under the EVM create limit. Runs under `--code-size-limit 60000`.
    function _deployExecutor(address factory_, ExecutorInitParams memory params_)
        internal
        returns (StargateCrosschainExecutor)
    {
        bytes memory args = abi.encode(address(endpoint), address(usdc), address(pool), ASSET_ID, factory_, params_);
        return StargateCrosschainExecutor(
            payable(vm.deployCode("StargateCrosschainExecutor.sol:StargateCrosschainExecutor", args))
        );
    }

    // ---------------------------------------------------------------------
    // Bring-up helpers
    // ---------------------------------------------------------------------

    function _registerRemote() internal {
        vm.prank(manager);
        executor.registerChain(REMOTE_CHAIN, REMOTE_EID, _commandLaneOptions(REMOTE_EID));
    }

    /// @dev A `msgType 1` (command lane) enforced-options blob with a usable executor `lzReceive` gas, the
    ///      shape `registerChain` requires since IL-8296, with a lane at or above the IL-8625 minimum. The production
    ///      script `RegisterRemoteChains.s.sol` (deploy repo) registered 2,000,000 and must be raised to the new minimum.
    function _commandLaneOptions(uint32 eid_) internal view returns (bytes memory) {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: eid_,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(commandLaneGas, 0)
        });
        return abi.encode(options);
    }

    /// @notice Register the remote chain, request+ACK a dispatcher, then ACK the auto initial UPDATE_VAULTS
    ///         so the executor lands with frontier=0 (a command ACK is value-neutral and never moves it,
    ///         IL-8257), commandConfigEpoch=1, nextCommandSequence=1 and a free command slot.
    function _readyDispatcher() internal {
        _registerRemote();
        address[] memory empty = new address[](0);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, empty);
        // requestId == 1 (first request on the mock factory).
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);

        // Clear the auto initial UPDATE_VAULTS by acking it (dispatcher stateVersion stays 0, IL-8257).
        (,,,, bytes32 commandId,,) = executor.activeCommand(REMOTE_CHAIN);
        _deliverCommandAck(commandId, 0, 0, 0);
    }

    // ---------------------------------------------------------------------
    // Inbound delivery helpers (Origin uses the same-address self peer)
    // ---------------------------------------------------------------------

    function _selfPeer() internal view returns (bytes32) {
        return bytes32(uint256(uint160(address(executor))));
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(address(executor), REMOTE_EID, _selfPeer(), keccak256("guid"), envelope_);
    }

    /// @notice Deliver a SUCCESS ACK the way an honest dispatcher would build it: a config update that
    ///         actually ran advances the dispatcher's epoch by one, anything else leaves it untouched.
    function _deliverCommandAck(bytes32 commandId_, uint64 sequence_, uint64 stateVersion_, int256 valueDeltaSD_)
        internal
    {
        (, bool isConfigUpdate,,,,, uint64 newConfigEpoch) = executor.activeCommand(REMOTE_CHAIN);
        uint64 dispatcherEpoch = isConfigUpdate ? newConfigEpoch : executor.chainConfigEpoch(REMOTE_CHAIN);
        _deliverCommandAckAs(
            commandId_, sequence_, stateVersion_, valueDeltaSD_, CommandResolution.SUCCEEDED, dispatcherEpoch
        );
    }

    /// @notice Deliver a CANCEL resolution ACK: the dispatcher applied nothing, so its epoch is unchanged.
    function _deliverCommandCancelAck(bytes32 commandId_, uint64 sequence_, uint64 stateVersion_) internal {
        _deliverCommandAckAs(
            commandId_,
            sequence_,
            stateVersion_,
            0,
            CommandResolution.CANCELLED,
            executor.chainConfigEpoch(REMOTE_CHAIN)
        );
    }

    /// @notice Full-control ACK delivery for tests that need to craft a specific (or dishonest) receipt.
    function _deliverCommandAckAs(
        bytes32 commandId_,
        uint64 sequence_,
        uint64 stateVersion_,
        int256 valueDeltaSD_,
        CommandResolution resolution_,
        uint64 dispatcherConfigEpoch_
    ) internal {
        _deliver(
            CrosschainMessages.encodeCommandAck(
                CommandAck({
                    commandId: commandId_,
                    sequence: sequence_,
                    stateVersion: stateVersion_,
                    dispatcherConfigEpoch: dispatcherConfigEpoch_,
                    resolution: resolution_,
                    valueDeltaSD: valueDeltaSD_
                })
            )
        );
    }

    function _deliverCommandNack(bytes32 commandId_, uint64 sequence_) internal {
        _deliver(CrosschainMessages.encodeCommandNack(CommandNack({commandId: commandId_, sequence: sequence_})));
    }

    function _deliverTransferSettled(
        bytes32 transferId_,
        bytes32 guid_,
        uint256 amountReceivedSD_,
        uint64 stateVersion_
    ) internal {
        _deliver(
            CrosschainMessages.encodeTransferSettled(
                TransferSettled({
                    transferId: transferId_,
                    guid: guid_,
                    amountReceivedSD: amountReceivedSD_,
                    stateVersion: stateVersion_
                })
            )
        );
    }

    /// @dev Dispatcher post-debit balance carried by the next `_deliverReturnStarted` (IL-8606); 0 = none.
    uint256 internal returnStartedRemoteBalanceSD;

    function _deliverReturnStarted(
        bytes32 requestId_,
        bytes32 guid_,
        uint256 amountSentSD_,
        uint256 amountReceivedSD_,
        uint64 stateVersion_
    ) internal {
        _deliver(
            CrosschainMessages.encodeReturnStarted(
                ReturnStarted({
                    requestId: requestId_,
                    guid: guid_,
                    amountSentSD: amountSentSD_,
                    amountReceivedSD: amountReceivedSD_,
                    stateVersion: stateVersion_,
                    remoteBalanceSD: returnStartedRemoteBalanceSD
                })
            )
        );
    }

    function _deliverReturnRejected(bytes32 requestId_) internal {
        _deliverReturnRejected(requestId_, ReturnRejectReason.NO_TRACKED_IDLE);
    }

    function _deliverReturnRejected(bytes32 requestId_, ReturnRejectReason reason_) internal {
        _deliver(CrosschainMessages.encodeReturnRejected(ReturnRejected({requestId: requestId_, reason: reason_})));
    }

    /// @notice Deliver a return-asset compose to the executor (tokens are minted separately to simulate the
    ///         physical Stargate credit).
    function _deliverReturnCompose(bytes32 requestId_, bytes32 guid_, uint256 amountLD_) internal {
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: requestId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(executor), REMOTE_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(executor), address(pool), guid_, composeMsg);
    }

    // ---------------------------------------------------------------------
    // Manager actions with event capture
    // ---------------------------------------------------------------------

    /// @notice Fund the executor with fresh untracked USDC and bridge it out; returns the recorded ids.
    function _sendAsset(uint256 amount_, uint256 minAmountLD_)
        internal
        returns (bytes32 transferId, bytes32 guid, uint256 amountSD)
    {
        usdc.mint(address(executor), amount_);
        vm.recordLogs();
        vm.prank(manager);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, minAmountLD_, "");
        (transferId, guid, amountSD) = _captureAssetSent();
    }

    function _captureAssetSent() internal returns (bytes32 transferId, bytes32 guid, uint256 amountSD) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ASSET_SENT_TOPIC) {
                // no indexed params: dstChainId leads the data section
                (, transferId, guid, amountSD) = abi.decode(logs[i].data, (uint256, bytes32, bytes32, uint256));
                return (transferId, guid, amountSD);
            }
        }
        revert("AssetSentToDispatcher not emitted");
    }

    /// @notice Request assets back from the dispatcher; returns the recorded request id + accounting bound.
    function _requestAssets(uint256 amount_, uint256 minReturn_)
        internal
        returns (bytes32 requestId, uint256 amountSD, uint256 maxAccountedSD)
    {
        vm.recordLogs();
        vm.prank(manager);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, amount_, minReturn_, "");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == RETURN_REQUESTED_TOPIC) {
                // no indexed params: dstChainId leads the data section
                (, requestId, amountSD, maxAccountedSD) = abi.decode(logs[i].data, (uint256, bytes32, uint256, uint256));
                return (requestId, amountSD, maxAccountedSD);
            }
        }
        revert("ReturnRequested not emitted");
    }

    bytes32 internal constant RGUID = keccak256("return-guid");

    /// @notice Bridge 100e6 out and settle it: leaves settledRemoteBalance = 100e6, frontier = 1.
    function _settle100() internal {
        (bytes32 transferId, bytes32 guid,) = _sendAsset(100e6, 0);
        _deliverTransferSettled(transferId, guid, 100e6, 1);
    }

    /// @notice Bring up + settle 100e6 + recall 40e6 to idle (metadata-first): idleLedger = 40e6 backed by
    ///         40e6 physical USDC, settledRemoteBalance = 60e6, frontier = 2.
    function _readyAndFundIdle40() internal {
        _readyDispatcher();
        _settle100();
        (bytes32 requestId,,) = _requestAssets(40e6, 0);
        _deliverReturnStarted(requestId, RGUID, 40e6, 40e6, 2);
        usdc.mint(address(executor), 40e6);
        _deliverReturnCompose(requestId, RGUID, 40e6);
    }

    /// @notice Read the current active-command id for the remote chain.
    function _activeCommandId() internal view returns (bytes32 commandId) {
        (,,,, commandId,,) = executor.activeCommand(REMOTE_CHAIN);
    }

    function _activeCommandStatus() internal view returns (CommandStatus status) {
        (,,, status,,,) = executor.activeCommand(REMOTE_CHAIN);
    }
}
