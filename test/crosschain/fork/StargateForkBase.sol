// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

// The fork suites print gas-budget and fee-quote reports for operators, so console output is intended here.
/* solhint-disable no-console */

import {Test, Vm} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";
import {
    ILayerZeroEndpointV2,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {StargateCrosschainExecutor} from "../../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";
import {StargateCrosschainDispatcher} from "../../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {ExecutorInitParams} from "../../../contracts/crosschain/interfaces/ICrosschainFactory.sol";
import {MockCrosschainFactory} from "../mocks/MockCrosschainFactory.sol";

/// @title StargateForkBase
/// @notice Pinned-block fork scaffolding for the Stargate transport against the REAL LayerZero EndpointV2, the
///         real Stargate V2 USDC pools and real USDC (IL-8458 / Codex audit O-14). The executor lives on an
///         Ethereum fork and the dispatcher on an Arbitrum fork, both at the same address (`APP`), which is
///         the production same-address model. Messages cross forks as real packets: the source endpoint's
///         `PacketSent` is decoded and delivered on the destination endpoint through `verify` (pranked as the
///         configured receive library, i.e. the DVN quorum step) followed by `lzReceive`, and Stargate composes
///         through `sendCompose` (emitted by the real pool) followed by `lzCompose`.
/// @dev What is simulated, and why:
///      - The DVN/receive-library step: `verify` is pranked as the receive library the endpoint itself reports
///        for the receiver. Everything after it (nonce/payload bookkeeping, `lzReceive`, `lzCompose`, retry,
///        skip/nilify/clear) is the real EndpointV2 code.
///      - Same address on two forks: `deployCodeTo` runs the real constructor at `APP` on each fork. CREATE3 would
///        give the same result; the test only needs the address equality the peers rely on.
///      - The factory: `MockCrosschainFactory` on the executor side, `FACTORY_PLACEHOLDER` on the dispatcher side.
///        The factory is not what these tests exercise (see `FactoryPathConfigOptionsTest`).
///      - Stargate's own token channel (TokenMessaging -> TokenMessaging) has live traffic, so the two pinned
///        forks disagree on its nonces. A Stargate packet is delivered at the destination's next inbound nonce
///        (`inboundNonce + 1`); every other byte of the packet is the one the source fork produced. The app's own
///        channel (`APP` -> `APP`) is fresh on both forks, so its packets keep their source nonce.
abstract contract StargateForkBase is Test {
    using OptionsBuilder for bytes;

    // ---------------------------------------------------------------------
    // Pinned forks
    // ---------------------------------------------------------------------

    uint256 internal constant ETHEREUM_FORK_BLOCK = 26_082_000;
    uint256 internal constant ARBITRUM_FORK_BLOCK = 510_000_000;
    uint256 internal constant BASE_FORK_BLOCK = 51_945_000;
    /// @dev Later than all three pinned blocks (latest is Base at 1_790_679_347). Every fork is warped here so
    ///      command deadlines and staleness clocks compare like-for-like across chains.
    uint256 internal constant COMMON_TIMESTAMP = 1_790_690_000;

    // ---------------------------------------------------------------------
    // Real addresses (verified on each fork: `eid()`, `token()`)
    // ---------------------------------------------------------------------

    address internal constant LZ_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;

    uint256 internal constant ETHEREUM_CHAIN_ID = 1;
    uint32 internal constant ETHEREUM_EID = 30101;
    address internal constant ETHEREUM_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant ETHEREUM_STARGATE_USDC = 0xc026395860Db2d07ee33e05fE50ed7bD583189C7;

    uint256 internal constant ARBITRUM_CHAIN_ID = 42161;
    uint32 internal constant ARBITRUM_EID = 30110;
    address internal constant ARBITRUM_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARBITRUM_STARGATE_USDC = 0xe8CDF27AcD73a434D661C84887215F7598e7d0d3;
    /// @dev Fluid fUSDC on Arbitrum: a real ERC-4626 over native USDC, used as the remote deposit target.
    address internal constant ARBITRUM_FLUID_USDC = 0x1A996cb54bb95462040408C06122D45D6Cdb6096;

    uint256 internal constant BASE_CHAIN_ID = 8453;
    uint32 internal constant BASE_EID = 30184;
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant BASE_STARGATE_USDC = 0x27a16dc786820B16E5c9028b75B99F6f604b5d26;

    // ---------------------------------------------------------------------
    // Deployment gas budgets (the values production configures)
    // ---------------------------------------------------------------------

    /// @dev Executor command lane, msgType 1: the deploy repo's `RegisterRemoteChains.s.sol` registers 2,000,000 and must be
    ///      raised to at least `COMMAND_LANE_MIN_RECEIVE_GAS`; 4M here. It budgets commands delivered to the dispatcher only.
    uint128 internal constant COMMAND_LANE_GAS = 4_000_000;
    /// @dev Dispatcher -> executor receipts (ACK, NACK, TRANSFER_SETTLED, RETURN_REJECTED, RETURN_STARTED), msgType 1.
    ///      Mirrors the private `StargateCrosschainFactory.DISPATCHER_RECEIVE_GAS` that `_deployDispatcher` registers; it is
    ///      separate from the command lane and is pinned against the real factory by `StargateFactoryDispatcherReceiptGasTest`.
    uint128 internal constant DISPATCHER_RECEIVE_GAS = 2_000_000;
    /// @dev The lane the apps are deployed / registered with; defaults to `COMMAND_LANE_GAS`, the pre-check pin test varies it.
    uint128 internal laneGas = COMMAND_LANE_GAS;
    /// @dev Dispatcher -> executor return leg, msgType 2 (`StargateCrosschainFactory` RETURN_ASSET_*_GAS).
    uint128 internal constant RETURN_ASSET_RECEIVE_GAS = 250_000;
    uint128 internal constant RETURN_ASSET_COMPOSE_GAS = 1_500_000;
    /// @dev Executor -> dispatcher asset send, caller-supplied options (`BridgeTestUsdc.s.sol`).
    uint128 internal constant ASSET_SEND_RECEIVE_GAS = 250_000;
    uint128 internal constant ASSET_SEND_COMPOSE_GAS = 1_500_000;
    /// @dev Required headroom: measured gas * 13 / 10 must fit the configured budget.
    uint256 internal constant GAS_MARGIN_NUM = 13;
    uint256 internal constant GAS_MARGIN_DEN = 10;

    bytes32 internal constant ASSET_ID = keccak256("USDC");
    address internal constant APP = address(uint160(uint256(keccak256("ipor.fork.stargate.app"))));
    address internal constant FACTORY_PLACEHOLDER = address(0xF);

    bytes32 internal constant PACKET_SENT_TOPIC = keccak256("PacketSent(bytes,bytes,address)");
    bytes32 internal constant COMPOSE_SENT_TOPIC = keccak256("ComposeSent(address,address,bytes32,uint16,bytes)");

    // ---------------------------------------------------------------------
    // Actors and state
    // ---------------------------------------------------------------------

    address internal manager = makeAddr("manager");
    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal proposer = makeAddr("proposer");
    address internal approver = makeAddr("approver");

    uint256 internal ethereumFork;
    uint256 internal arbitrumFork;

    MockCrosschainFactory internal factory;
    StargateCrosschainExecutor internal executor;
    StargateCrosschainDispatcher internal dispatcher;

    ILayerZeroEndpointV2 internal constant ENDPOINT = ILayerZeroEndpointV2(LZ_ENDPOINT);

    struct Packet {
        Origin origin;
        uint32 dstEid;
        address receiver;
        bytes32 guid;
        bytes message;
    }

    struct Compose {
        address from;
        address to;
        bytes32 guid;
        uint16 index;
        bytes message;
    }

    // ---------------------------------------------------------------------
    // Fork + deployment
    // ---------------------------------------------------------------------

    function _createForks() internal {
        ethereumFork = vm.createFork(vm.envString("ETHEREUM_PROVIDER_URL"), ETHEREUM_FORK_BLOCK);
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_PROVIDER_URL"), ARBITRUM_FORK_BLOCK);
        vm.selectFork(ethereumFork);
        vm.warp(COMMON_TIMESTAMP);
        vm.selectFork(arbitrumFork);
        vm.warp(COMMON_TIMESTAMP);
    }

    function _executorParams() internal view returns (ExecutorInitParams memory) {
        return ExecutorInitParams({
            assetId: ASSET_ID,
            manager: manager,
            admin: admin,
            rescueGuardian: guardian,
            rescueDelay: 3 days,
            balanceProposer: proposer,
            balanceApprover: approver,
            stalenessMax: 1 days,
            bigChangeBps: 1000,
            minUpdateInterval: 10 minutes,
            deploymentTtl: 1 days,
            transferStalenessMax: 2 days
        });
    }

    /// @notice Deploy the executor on the Ethereum fork and the dispatcher on the Arbitrum fork, both at `APP`,
    ///         and fund both with native gas budget.
    function _deployApps() internal {
        vm.selectFork(ethereumFork);
        factory = new MockCrosschainFactory();
        factory.setPath(ARBITRUM_CHAIN_ID, ARBITRUM_EID);
        deployCodeTo(
            "StargateCrosschainExecutor.sol:StargateCrosschainExecutor",
            abi.encode(
                LZ_ENDPOINT, ETHEREUM_USDC, ETHEREUM_STARGATE_USDC, ASSET_ID, address(factory), _executorParams()
            ),
            APP
        );
        executor = StargateCrosschainExecutor(payable(APP));
        vm.deal(APP, 10 ether);

        vm.selectFork(arbitrumFork);
        deployCodeTo(
            "StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher",
            abi.encode(
                LZ_ENDPOINT,
                ARBITRUM_USDC,
                ARBITRUM_STARGATE_USDC,
                ASSET_ID,
                FACTORY_PLACEHOLDER,
                admin,
                guardian,
                uint256(3 days),
                ETHEREUM_CHAIN_ID,
                ETHEREUM_EID,
                _dispatcherEnforcedOptions()
            ),
            APP
        );
        dispatcher = StargateCrosschainDispatcher(payable(APP));
        vm.deal(APP, 10 ether);
    }

    /// @dev The enforced options `StargateCrosschainFactory._deployDispatcher` gives a dispatcher (receipts at `DISPATCHER_RECEIVE_GAS`).
    function _dispatcherEnforcedOptions() internal view returns (bytes memory) {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](2);
        options[0] = EnforcedOptionParam({
            eid: ETHEREUM_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(DISPATCHER_RECEIVE_GAS, 0)
        });
        options[1] = EnforcedOptionParam({
            eid: ETHEREUM_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(RETURN_ASSET_RECEIVE_GAS, 0)
                .addExecutorLzComposeOption(0, RETURN_ASSET_COMPOSE_GAS, 0)
        });
        return abi.encode(options);
    }

    /// @dev The command-lane options (`laneGas`) the executor registers; the deploy repo's script must register at least the minimum.
    function _commandLaneOptions(uint32 eid_) internal view returns (bytes memory) {
        EnforcedOptionParam[] memory options = new EnforcedOptionParam[](1);
        options[0] = EnforcedOptionParam({
            eid: eid_, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(laneGas, 0)
        });
        return abi.encode(options);
    }

    /// @dev Caller options for an executor -> dispatcher asset send (`BridgeTestUsdc.s.sol`).
    function _assetSendOptions() internal pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(ASSET_SEND_RECEIVE_GAS, 0)
            .addExecutorLzComposeOption(0, ASSET_SEND_COMPOSE_GAS, 0);
    }

    // ---------------------------------------------------------------------
    // Bring-up: register, request, ACK the initial UPDATE_VAULTS through the real endpoints
    // ---------------------------------------------------------------------

    /// @return updateVaultsGas Gas of the dispatcher-side `lzReceive` for the initial UPDATE_VAULTS.
    /// @return ackGas Gas of the executor-side `lzReceive` for its ACK.
    function _bringUp() internal returns (uint256 updateVaultsGas, uint256 ackGas) {
        vm.selectFork(ethereumFork);
        vm.prank(manager);
        executor.registerChain(ARBITRUM_CHAIN_ID, ARBITRUM_EID, _commandLaneOptions(ARBITRUM_EID));
        vm.prank(manager);
        executor.createDispatcher(ARBITRUM_CHAIN_ID, new address[](0));

        vm.recordLogs();
        factory.ackDispatcher(APP, 1, ARBITRUM_CHAIN_ID); // sends the initial UPDATE_VAULTS through the endpoint
        Packet memory updateVaults = _takePacket(APP);

        vm.selectFork(arbitrumFork);
        updateVaultsGas = _deliver(updateVaults, laneGas);
        Packet memory ack = _takePacket(APP);

        vm.selectFork(ethereumFork);
        ackGas = _deliver(ack, DISPATCHER_RECEIVE_GAS);
        vm.recordLogs(); // drop the executor-side logs
    }

    // ---------------------------------------------------------------------
    // Packet capture and delivery
    // ---------------------------------------------------------------------

    /// @notice Take the last `PacketSent` emitted by the current fork's endpoint whose sender is `sender_`.
    /// @dev Consumes the recorded logs (`vm.getRecordedLogs`); call `vm.recordLogs()` before the send.
    function _takePacket(address sender_) internal returns (Packet memory packet) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT || logs[i].topics[0] != PACKET_SENT_TOPIC) continue;
            (bytes memory encoded,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            Packet memory candidate = this.decodePacket(encoded);
            if (address(uint160(uint256(candidate.origin.sender))) == sender_) {
                packet = candidate;
                found = true;
            }
        }
        require(found, "fork: no PacketSent from sender");
    }

    /// @notice Take both the app packet and the Stargate token packet emitted by one call.
    function _takeTwoPackets(address appSender_) internal returns (Packet memory appPacket, Packet memory tokenPacket) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundApp;
        bool foundToken;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT || logs[i].topics[0] != PACKET_SENT_TOPIC) continue;
            (bytes memory encoded,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            Packet memory candidate = this.decodePacket(encoded);
            if (address(uint160(uint256(candidate.origin.sender))) == appSender_) {
                appPacket = candidate;
                foundApp = true;
            } else {
                tokenPacket = candidate;
                foundToken = true;
            }
        }
        require(foundApp && foundToken, "fork: expected app + token packets");
    }

    /// @notice Take the Stargate token packet (the only `PacketSent` not sent by `APP`).
    function _takeTokenPacket() internal returns (Packet memory packet) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT || logs[i].topics[0] != PACKET_SENT_TOPIC) continue;
            (bytes memory encoded,,) = abi.decode(logs[i].data, (bytes, bytes, address));
            Packet memory candidate = this.decodePacket(encoded);
            if (address(uint160(uint256(candidate.origin.sender))) != APP) {
                packet = candidate;
                found = true;
            }
        }
        require(found, "fork: no Stargate token packet");
    }

    /// @notice Take the `ComposeSent` to `to_` emitted on the current fork.
    function _takeCompose(address to_) internal returns (Compose memory compose) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT || logs[i].topics[0] != COMPOSE_SENT_TOPIC) continue;
            (address from, address to, bytes32 guid, uint16 index, bytes memory message) =
                abi.decode(logs[i].data, (address, address, bytes32, uint16, bytes));
            if (to == to_) {
                compose = Compose({from: from, to: to, guid: guid, index: index, message: message});
                found = true;
            }
        }
        require(found, "fork: no ComposeSent");
    }

    /// @notice PacketV1Codec layout: version(1) | nonce(8) | srcEid(4) | sender(32) | dstEid(4) | receiver(32) |
    ///         guid(32) | message.
    function decodePacket(bytes calldata encoded_) external pure returns (Packet memory packet) {
        packet.origin = Origin({
            srcEid: uint32(bytes4(encoded_[9:13])),
            sender: bytes32(encoded_[13:45]),
            nonce: uint64(bytes8(encoded_[1:9]))
        });
        packet.dstEid = uint32(bytes4(encoded_[45:49]));
        packet.receiver = address(uint160(uint256(bytes32(encoded_[49:81]))));
        packet.guid = bytes32(encoded_[81:113]);
        packet.message = encoded_[113:];
    }

    /// @notice Verify `packet_` on the current fork as its receive library would, without executing it.
    function _verify(Packet memory packet_) internal returns (Origin memory origin) {
        origin = packet_.origin;
        if (packet_.receiver != APP) {
            // Stargate's token channel: deliver at the destination's next inbound nonce (see contract NatSpec).
            origin.nonce = ENDPOINT.inboundNonce(packet_.receiver, origin.srcEid, origin.sender) + 1;
        }
        (address receiveLib,) = ENDPOINT.getReceiveLibrary(packet_.receiver, origin.srcEid);
        vm.prank(receiveLib);
        ENDPOINT.verify(origin, packet_.receiver, keccak256(abi.encodePacked(packet_.guid, packet_.message)));
    }

    /// @notice Verify and execute `packet_` through the real endpoint with exactly `gasLimit_` gas, the way the
    ///         LayerZero executor does. Starts log recording so the caller can take the resulting packets.
    /// @return gasUsed Gas consumed by `endpoint.lzReceive` (endpoint bookkeeping + the app handler).
    function _deliver(Packet memory packet_, uint256 gasLimit_) internal returns (uint256 gasUsed) {
        Origin memory origin = _verify(packet_);
        vm.recordLogs();
        (bool ok, uint256 used) = _lzReceive(origin, packet_, gasLimit_);
        require(ok, "fork: lzReceive failed within the configured gas");
        gasUsed = used;
    }

    function _lzReceive(Origin memory origin_, Packet memory packet_, uint256 gasLimit_)
        internal
        returns (bool ok, uint256 gasUsed)
    {
        bytes memory callData =
            abi.encodeCall(ENDPOINT.lzReceive, (origin_, packet_.receiver, packet_.guid, packet_.message, ""));
        uint256 before = gasleft();
        (ok,) = LZ_ENDPOINT.call{gas: gasLimit_}(callData);
        gasUsed = before - gasleft();
    }

    /// @notice Execute a queued compose through the real endpoint with exactly `gasLimit_` gas.
    function _compose(Compose memory compose_, uint256 gasLimit_) internal returns (uint256 gasUsed) {
        bytes memory callData = abi.encodeCall(
            ENDPOINT.lzCompose, (compose_.from, compose_.to, compose_.guid, compose_.index, compose_.message, "")
        );
        vm.recordLogs();
        uint256 before = gasleft();
        (bool ok,) = LZ_ENDPOINT.call{gas: gasLimit_}(callData);
        gasUsed = before - gasleft();
        require(ok, "fork: lzCompose failed within the configured gas");
    }

    /// @notice Deliver a Stargate token packet on the current fork and run the compose it queues for `APP`.
    /// @return receiveGas Gas of Stargate's token `lzReceive` (TokenMessaging -> pool credit -> sendCompose).
    /// @return composeGas Gas of the app's `lzCompose`.
    function _deliverTokenAndCompose(Packet memory tokenPacket_, uint256 receiveGasLimit_, uint256 composeGasLimit_)
        internal
        returns (uint256 receiveGas, uint256 composeGas)
    {
        // Only our own lzReceive budget: the live executor adds Stargate's enforced receive gas on top, so this
        // is stricter than production.
        receiveGas = _deliver(tokenPacket_, receiveGasLimit_);
        Compose memory compose = _takeCompose(APP);
        composeGas = _compose(compose, composeGasLimit_);
    }

    // ---------------------------------------------------------------------
    // Gas bookkeeping
    // ---------------------------------------------------------------------

    function _assertGasFits(string memory label_, uint256 used_, uint256 budget_) internal pure {
        console2.log(string.concat("GAS | ", label_, " | used / budget:"), used_, budget_);
        assertLe(used_ * GAS_MARGIN_NUM / GAS_MARGIN_DEN, budget_, string.concat("gas margin: ", label_));
    }
}
