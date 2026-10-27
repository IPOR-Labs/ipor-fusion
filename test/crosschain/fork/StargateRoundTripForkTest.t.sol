// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";

import {BusinessAction, CommandStatus, MsgType} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages, ReturnRejected} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateForkBase} from "./StargateForkBase.sol";
import {DEFAULT_COMMAND_BUDGET} from "../CommandBudget.sol";

/// @title StargateRoundTripForkTest
/// @notice Real two-fork round trips (Ethereum executor <-> Arbitrum dispatcher) through the real EndpointV2, the
///         real Stargate V2 USDC pools and a real ERC-4626 (Fluid fUSDC) on Arbitrum. Every inbound handler runs
///         with exactly the gas production configures, and the measured gas is checked against a 30% margin.
contract StargateRoundTripForkTest is StargateForkBase {
    uint256 internal constant SEND_AMOUNT = 1_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 400e6;

    function setUp() public {
        _createForks();
        _deployApps();
    }

    function testForkBringUpRoundTripThroughRealEndpoints() public {
        (uint256 updateVaultsGas, uint256 ackGas) = _bringUp();

        vm.selectFork(arbitrumFork);
        assertEq(dispatcher.commandConfigEpoch(), 1, "dispatcher applied the initial UPDATE_VAULTS");
        assertEq(dispatcher.nextCommandSequence(), 1);
        uint64 remoteVersion = dispatcher.stateVersion();

        vm.selectFork(ethereumFork);
        assertTrue(executor.hasDispatcher(ARBITRUM_CHAIN_ID));
        assertEq(executor.acknowledgedRemoteStateVersion(ARBITRUM_CHAIN_ID), remoteVersion);

        _assertGasFits("dispatcher lzReceive UPDATE_VAULTS (initial, empty)", updateVaultsGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive ACK (UPDATE_VAULTS)", ackGas, DISPATCHER_RECEIVE_GAS);
    }

    /// @notice Full lifecycle over the real transports: bridge USDC out through the real Stargate pool and
    ///         compose, settle, allowlist and deposit into / redeem from a real ERC-4626, then recall — first
    ///         with a floor above the real post-fee credit (clean BELOW_MINIMUM rejection, IL-8452), then with
    ///         the floor at the credit (real pool send back, metadata + compose on the executor).
    function testForkFullLifecycleThroughRealTransports() public {
        _bringUp();

        // 1. Executor -> dispatcher asset send, compose and TRANSFER_SETTLED.
        (uint256 receivedSD, uint256 poolReceiveGas, uint256 composeGas, uint256 settledGas) =
            _sendAssetToArbitrum(SEND_AMOUNT);
        vm.selectFork(arbitrumFork);
        assertEq(dispatcher.trackedIdle(), receivedSD, "compose credited the Stargate-delivered amount");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(APP), receivedSD, "real USDC delivered by the pool");
        vm.selectFork(ethereumFork);
        assertEq(executor.settledRemoteBalance(ARBITRUM_CHAIN_ID), receivedSD, "settled on the executor");
        _assertGasFits(
            "Stargate token lzReceive on Arbitrum (executor -> dispatcher leg)", poolReceiveGas, ASSET_SEND_RECEIVE_GAS
        );
        _assertGasFits("dispatcher lzCompose OUTBOUND_TRANSFER", composeGas, ASSET_SEND_COMPOSE_GAS);
        _assertGasFits("executor lzReceive TRANSFER_SETTLED", settledGas, DISPATCHER_RECEIVE_GAS);

        // 2. Allowlist the real vault, deposit, redeem.
        address[] memory vaults = new address[](1);
        vaults[0] = ARBITRUM_FLUID_USDC;
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(ARBITRUM_CHAIN_ID, vaults);
        (uint256 updateGas, uint256 updateAckGas) = _relayCommand();
        _assertGasFits("dispatcher lzReceive UPDATE_VAULTS (1 vault)", updateGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive ACK (UPDATE_VAULTS)", updateAckGas, DISPATCHER_RECEIVE_GAS);

        _sendBusinessCommand(
            BusinessAction.DEPOSIT, CrosschainMessages.encodeDepositAction(ARBITRUM_FLUID_USDC, DEPOSIT_AMOUNT, 1)
        );
        (uint256 depositGas, uint256 depositAckGas) = _relayCommand();
        vm.selectFork(arbitrumFork);
        uint256 shares = IERC20(ARBITRUM_FLUID_USDC).balanceOf(APP);
        assertGt(shares, 0, "real ERC-4626 shares minted to the dispatcher");
        assertEq(dispatcher.trackedIdle(), receivedSD - DEPOSIT_AMOUNT, "idle debited by the measured spend");
        _assertGasFits("dispatcher lzReceive COMMAND DEPOSIT (Fluid fUSDC)", depositGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive ACK (DEPOSIT)", depositAckGas, DISPATCHER_RECEIVE_GAS);

        _sendBusinessCommand(
            BusinessAction.REDEEM, CrosschainMessages.encodeRedeemAction(ARBITRUM_FLUID_USDC, shares, 1)
        );
        (uint256 redeemGas, uint256 redeemAckGas) = _relayCommand();
        vm.selectFork(arbitrumFork);
        assertEq(IERC20(ARBITRUM_FLUID_USDC).balanceOf(APP), 0, "all shares redeemed");
        uint256 idleAfterRedeem = dispatcher.trackedIdle();
        assertGe(idleAfterRedeem + 1, receivedSD - 1, "redeem returned the deposit (up to vault rounding)");
        _assertGasFits("dispatcher lzReceive COMMAND REDEEM (Fluid fUSDC)", redeemGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive ACK (REDEEM)", redeemAckGas, DISPATCHER_RECEIVE_GAS);

        // 3. Recall with the floor at the full amount: the real pool charges a fee, so the dispatcher must reject
        //    cleanly (IL-8452) instead of reverting inside sendToken.
        vm.selectFork(ethereumFork);
        uint256 settled = executor.settledRemoteBalance(ARBITRUM_CHAIN_ID);
        uint256 recallAmount = idleAfterRedeem < settled ? idleAfterRedeem : settled;
        vm.recordLogs();
        vm.prank(manager);
        executor.requestAssetsFromDispatcher(ARBITRUM_CHAIN_ID, recallAmount, recallAmount, "");
        Packet memory request = _takePacket(APP);
        bytes32 rejectedRequestId = _returnRequestId(request);

        vm.selectFork(arbitrumFork);
        uint256 usdcBefore = IERC20(ARBITRUM_USDC).balanceOf(APP);
        uint256 rejectGas = _deliver(request, COMMAND_LANE_GAS);
        Packet memory rejection = _takePacket(APP);
        assertTrue(dispatcher.recallConsumed(rejectedRequestId), "rejection is terminal");
        assertEq(IERC20(ARBITRUM_USDC).balanceOf(APP), usdcBefore, "nothing sent to the pool");
        assertEq(IERC20(ARBITRUM_USDC).allowance(APP, ARBITRUM_STARGATE_USDC), 0, "no allowance left");
        (MsgType rejectionType, bytes memory rejectionData) = CrosschainMessages.decodeEnvelope(rejection.message);
        assertEq(uint8(rejectionType), uint8(MsgType.RETURN_REJECTED), "RETURN_REJECTED sent");
        ReturnRejected memory rej = CrosschainMessages.decodeReturnRejected(rejectionData);
        assertEq(rej.requestId, rejectedRequestId);
        _assertGasFits("dispatcher lzReceive RETURN_ASSETS_REQUEST (rejected)", rejectGas, COMMAND_LANE_GAS);

        vm.selectFork(ethereumFork);
        uint256 rejectedGas = _deliver(rejection, DISPATCHER_RECEIVE_GAS);
        assertEq(executor.pendingTransferCount(ARBITRUM_CHAIN_ID), 0, "rejection released the recall slot");
        _assertGasFits("executor lzReceive RETURN_REJECTED", rejectedGas, DISPATCHER_RECEIVE_GAS);

        // 4. Recall with the floor at the real quoted credit: sent through the real pool.
        vm.selectFork(arbitrumFork);
        uint256 credit = _quoteCredit(ARBITRUM_STARGATE_USDC, ETHEREUM_EID, recallAmount);
        assertLt(credit, recallAmount, "the real pool charges a fee on the amount");
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.requestAssetsFromDispatcher(ARBITRUM_CHAIN_ID, recallAmount, credit, "");
        request = _takePacket(APP);

        vm.selectFork(arbitrumFork);
        uint256 returnGas = _deliver(request, COMMAND_LANE_GAS);
        (Packet memory returnStarted, Packet memory returnToken) = _takeTwoPackets(APP);
        _assertGasFits("dispatcher lzReceive RETURN_ASSETS_REQUEST (real pool send)", returnGas, COMMAND_LANE_GAS);

        vm.selectFork(ethereumFork);
        uint256 startedGas = _deliver(returnStarted, DISPATCHER_RECEIVE_GAS);
        (uint256 returnPoolGas, uint256 returnComposeGas) =
            _deliverTokenAndCompose(returnToken, RETURN_ASSET_RECEIVE_GAS, RETURN_ASSET_COMPOSE_GAS);
        assertEq(executor.idleLedger(), credit, "returned credit is claimable idle on the executor");
        assertEq(IERC20(ETHEREUM_USDC).balanceOf(APP), credit, "real USDC delivered by the Ethereum pool");
        _assertGasFits("executor lzReceive RETURN_STARTED", startedGas, DISPATCHER_RECEIVE_GAS);
        _assertGasFits("Stargate token lzReceive on Ethereum (return leg)", returnPoolGas, RETURN_ASSET_RECEIVE_GAS);
        _assertGasFits("executor lzCompose return delivery", returnComposeGas, RETURN_ASSET_COMPOSE_GAS);
    }

    /// @notice A business command that fails on the dispatcher is NACKed, retried and cancelled over the real
    ///         endpoints; every receipt lands within the configured gas.
    function testForkFailedCommandNackRetryAndCancel() public {
        _bringUp();
        _sendAssetToArbitrum(SEND_AMOUNT);

        address[] memory vaults = new address[](1);
        vaults[0] = ARBITRUM_FLUID_USDC;
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(ARBITRUM_CHAIN_ID, vaults);
        _relayCommand();

        // minShares unreachable: the business action reverts -> FAILED + NACK.
        _sendBusinessCommand(
            BusinessAction.DEPOSIT,
            CrosschainMessages.encodeDepositAction(ARBITRUM_FLUID_USDC, DEPOSIT_AMOUNT, type(uint128).max)
        );
        (uint256 failGas, uint256 nackGas) = _relayCommand();
        (,,, CommandStatus status, bytes32 commandId,,) = executor.activeCommand(ARBITRUM_CHAIN_ID);
        assertEq(uint8(status), uint8(CommandStatus.FAILED), "executor saw the NACK");
        _assertGasFits("dispatcher lzReceive COMMAND DEPOSIT (fails -> NACK)", failGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive NACK", nackGas, DISPATCHER_RECEIVE_GAS);

        vm.recordLogs();
        vm.prank(manager);
        executor.retryCommand(ARBITRUM_CHAIN_ID);
        (uint256 retryGas, uint256 retryNackGas) = _relayCommand();
        vm.selectFork(arbitrumFork);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.FAILED), "retry failed again");
        _assertGasFits("dispatcher lzReceive RETRY_COMMAND (fails -> NACK)", retryGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive NACK (retry)", retryNackGas, DISPATCHER_RECEIVE_GAS);

        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.cancelCommand(ARBITRUM_CHAIN_ID);
        (uint256 cancelGas, uint256 cancelAckGas) = _relayCommand();
        vm.selectFork(arbitrumFork);
        assertEq(uint8(dispatcher.commandStatus(commandId)), uint8(CommandStatus.CANCELLED));
        vm.selectFork(ethereumFork);
        (bool active,,,,,,) = executor.activeCommand(ARBITRUM_CHAIN_ID);
        assertFalse(active, "cancel ACK freed the command slot");
        _assertGasFits("dispatcher lzReceive CANCEL_COMMAND", cancelGas, COMMAND_LANE_GAS);
        _assertGasFits("executor lzReceive ACK (cancel)", cancelAckGas, DISPATCHER_RECEIVE_GAS);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _sendAssetToArbitrum(uint256 amount_)
        internal
        returns (uint256 receivedSD, uint256 poolReceiveGas, uint256 composeGas, uint256 settledGas)
    {
        vm.selectFork(ethereumFork);
        deal(ETHEREUM_USDC, APP, amount_);
        uint256 minAmount = _quoteCredit(ETHEREUM_STARGATE_USDC, ARBITRUM_EID, amount_);
        vm.recordLogs();
        vm.prank(manager);
        executor.sendAssetToDispatcher(ARBITRUM_CHAIN_ID, amount_, minAmount, _assetSendOptions());
        Packet memory token = _takeTokenPacket();
        receivedSD = minAmount; // USDC: 6 local = 6 shared decimals

        vm.selectFork(arbitrumFork);
        (poolReceiveGas, composeGas) = _deliverTokenAndCompose(token, ASSET_SEND_RECEIVE_GAS, ASSET_SEND_COMPOSE_GAS);
        Packet memory settled = _takePacket(APP);

        vm.selectFork(ethereumFork);
        settledGas = _deliver(settled, DISPATCHER_RECEIVE_GAS);
    }

    /// @dev Manager sends a business command on the Ethereum fork; logs are recorded for `_relayCommand`.
    function _sendBusinessCommand(BusinessAction action_, bytes memory actionData_) internal {
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.sendCommandToDispatcher(
            ARBITRUM_CHAIN_ID,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(action_),
                minExecutionGas: DEFAULT_COMMAND_BUDGET,
                actionData: actionData_
            })
        );
    }

    /// @dev Relay the executor packet recorded on the Ethereum fork to the dispatcher, and its receipt back.
    function _relayCommand() internal returns (uint256 dispatcherGas, uint256 executorGas) {
        Packet memory command = _takePacket(APP);
        vm.selectFork(arbitrumFork);
        dispatcherGas = _deliver(command, COMMAND_LANE_GAS);
        Packet memory receipt = _takePacket(APP);
        vm.selectFork(ethereumFork);
        executorGas = _deliver(receipt, DISPATCHER_RECEIVE_GAS);
    }

    function _quoteCredit(address pool_, uint32 dstEid_, uint256 amount_) internal view returns (uint256) {
        (,, OFTReceipt memory receipt) = IStargate(pool_)
            .quoteOFT(
                SendParam({
                dstEid: dstEid_,
                to: bytes32(uint256(uint160(APP))),
                amountLD: amount_,
                minAmountLD: 0,
                extraOptions: "",
                composeMsg: "",
                oftCmd: ""
            })
            );
        return receipt.amountReceivedLD;
    }

    function _returnRequestId(Packet memory packet_) internal pure returns (bytes32) {
        (, bytes memory data) = CrosschainMessages.decodeEnvelope(packet_.message);
        return CrosschainMessages.decodeReturnAssetsRequest(data).requestId;
    }
}
