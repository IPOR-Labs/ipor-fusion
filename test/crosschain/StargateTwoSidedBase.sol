// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {CrosschainMessages, Command, OutboundTransfer} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateTwoSidedBase
/// @notice Harness that drives a REAL `StargateCrosschainExecutor` against a REAL
///         `StargateCrosschainDispatcher` on a single EVM, with the LayerZero payloads relayed BY HAND so
///         each test chooses the delivery order — and, just as importantly, can choose to never deliver a
///         message at all.
/// @dev Both contracts authenticate a same-address peer, so each side is delivered its OWN address as the
///      origin sender — exactly what a real cross-chain delivery looks like from that side. The dispatcher
///      must be constructed under the remote chain id (its constructor registers the executor path and
///      `_registerPath` rejects the local chain); runtime message handling never reads `block.chainid`.
///      `MockLzEndpoint` records every outbound message in one array, so relaying is by index.
abstract contract StargateTwoSidedBase is CrosschainTestBase {
    using OptionsBuilder for bytes;

    StargateCrosschainDispatcher internal dispatcher;
    MockRemoteVault internal remoteVault;

    /// @dev Index of the next unrelayed message in the shared endpoint's outbound log.
    uint256 internal relayCursor;

    function _twoSidedSetUp() internal {
        _baseSetUp(); // executor + endpoint + pool + factory, at LOCAL_CHAIN

        vm.chainId(REMOTE_CHAIN);
        dispatcher = _deployDispatcher();
        vm.chainId(LOCAL_CHAIN);

        vm.deal(address(dispatcher), 100 ether);
        vm.label(address(dispatcher), "StargateCrosschainDispatcher");

        remoteVault = new MockRemoteVault(IERC20(address(usdc)), "Remote Vault", "RVLT");
    }

    function _deployDispatcher() internal returns (StargateCrosschainDispatcher) {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: LOCAL_EID, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: LOCAL_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0)
                .addExecutorLzComposeOption(0, 1_500_000, 0)
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            ASSET_ID,
            address(0xF), // factory (unused on this path)
            admin,
            guardian,
            RESCUE_DELAY,
            LOCAL_CHAIN,
            LOCAL_EID,
            abi.encode(enforcedOptions)
        );
        return StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
    }

    // ---------------------------------------------------------------------
    // Manual relay (order — and non-delivery — is the whole point)
    // ---------------------------------------------------------------------

    /// @dev Deliver one recorded outbound message to whichever side it was addressed to.
    function _relayAt(uint256 index_) internal {
        MockLzEndpoint.SentMessage memory m = endpoint.sentAt(index_);
        if (m.dstEid == REMOTE_EID) {
            endpoint.deliverLz(
                address(dispatcher), LOCAL_EID, bytes32(uint256(uint160(address(dispatcher)))), m.guid, m.message
            );
        } else {
            endpoint.deliverLz(
                address(executor), REMOTE_EID, bytes32(uint256(uint160(address(executor)))), m.guid, m.message
            );
        }
    }

    /// @dev Relay the next message in send order.
    function _relayNext() internal {
        _relayAt(relayCursor++);
    }

    /// @dev Relay every message queued since the last drain, in send order.
    function _relayAll() internal {
        uint256 end = endpoint.sentCount();
        while (relayCursor < end) {
            _relayNext();
            end = endpoint.sentCount(); // a delivery can queue a receipt
        }
    }

    function _lastSentIndex() internal view returns (uint256) {
        return endpoint.sentCount() - 1;
    }

    // ---------------------------------------------------------------------
    // Bring-up: both sides in lockstep at commandConfigEpoch 1
    // ---------------------------------------------------------------------

    function _bringUpBothSides() internal {
        _registerRemote();
        address[] memory empty = new address[](0);
        vm.prank(manager);
        executor.createDispatcher(REMOTE_CHAIN, empty);
        factory.ackDispatcher(address(executor), 1, REMOTE_CHAIN);

        // The executor auto-sends the initial UPDATE_VAULTS. Run it through the REAL dispatcher and relay
        // the receipt back, so both epochs advance 0 -> 1 together instead of being faked.
        _relayAll();

        assertEq(executor.chainConfigEpoch(REMOTE_CHAIN), 1, "executor mirror bootstrapped");
        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher epoch bootstrapped");
        (bool active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
        assertFalse(active, "command slot free after bootstrap");
    }

    /// @dev Allowlist a real ERC-4626 over ASSET through the sequenced lane. Advances both epochs to 2.
    function _allowRemoteVault() internal {
        address[] memory vaults = new address[](1);
        vaults[0] = address(remoteVault);
        vm.prank(manager);
        executor.updatePlasmaVaults(REMOTE_CHAIN, vaults);
        _relayAll();
    }

    /// @dev Bridge `amount_` from the executor and credit it as the dispatcher's tracked idle, using the
    ///      real outbound record so the settlement receipt matches (guid + contiguous state version).
    function _bridgeToDispatcher(uint256 amount_) internal {
        (bytes32 transferId, bytes32 guid,) = _sendAsset(amount_, 0);
        usdc.mint(address(dispatcher), amount_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), LOCAL_EID, amount_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), guid, composeMsg);
        _relayAll(); // TRANSFER_SETTLED -> executor
    }

    function _depositCommand(uint256 amountSD_) internal view returns (Command memory) {
        return Command({
            commandId: bytes32(0), // the executor allocates the authoritative id
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.DEPOSIT),
            minExecutionGas: DEFAULT_COMMAND_BUDGET,
            actionData: CrosschainMessages.encodeDepositAction(address(remoteVault), amountSD_, 0)
        });
    }

    function _commandSlotActive() internal view returns (bool active) {
        (active,,,,,,) = executor.activeCommand(REMOTE_CHAIN);
    }
}
