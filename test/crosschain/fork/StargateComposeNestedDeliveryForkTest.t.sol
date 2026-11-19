// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Test.sol";
import {IStargate} from "@stargatefinance/stg-evm-v2/src/interfaces/IStargate.sol";
import {SendParam, OFTReceipt} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oft/interfaces/IOFT.sol";
import {
    ILayerZeroEndpointV2,
    Origin
} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

import {BusinessAction, CommandResolution, MsgType} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    Command,
    CommandAck,
    CrosschainMessages,
    TransferSettled
} from "../../../contracts/crosschain/lib/CrosschainMessages.sol";
import {Observation} from "../../../contracts/crosschain/interfaces/ICrosschainDispatcher.sol";
import {MockRemoteVault} from "../mocks/MockRemoteVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "../CommandBudget.sol";
import {StargateForkBase} from "./StargateForkBase.sol";

/// @title NestedDeliveryVault
/// @notice A compromised third-party ERC-4626 on the dispatcher's allowlist (IL-9630 / Olympix M40). It is honest
///         for deposits and pays redemptions 1:1, but inside `redeem` it first executes an already VERIFIED Stargate
///         token packet through the REAL LayerZero EndpointV2. `EndpointV2.lzReceive` is permissionless for a
///         verified packet, so the real Stargate pool pays the in-flight transfer to the dispatcher and queues its
///         compose while the dispatcher is still inside its own measured balance-delta window.
/// @dev The delivery outcome is recorded instead of bubbled up: the sweep swallows a failed `redeem`, so the test
///      reads `lastDeliveryOk` / `lastDeliveryError` to prove the nested delivery really ran.
contract NestedDeliveryVault is MockRemoteVault {
    struct PendingPacket {
        Origin origin;
        address receiver;
        bytes32 guid;
        bytes message;
    }

    ILayerZeroEndpointV2 public immutable ENDPOINT_V2;
    address public immutable OPERATOR;

    PendingPacket internal _pending;
    bool public armed;
    bool public lastDeliveryOk;
    bytes public lastDeliveryError;
    uint256 public deliveries;

    constructor(IERC20 asset_, ILayerZeroEndpointV2 endpoint_) MockRemoteVault(asset_, "Nested Delivery Vault", "NDV") {
        ENDPOINT_V2 = endpoint_;
        OPERATOR = msg.sender;
    }

    /// @notice Stores a verified, not yet executed packet; the next `redeem` executes it first.
    function arm(Origin calldata origin_, address receiver_, bytes32 guid_, bytes calldata message_) external {
        require(msg.sender == OPERATOR, "only operator");
        _pending = PendingPacket({origin: origin_, receiver: receiver_, guid: guid_, message: message_});
        armed = true;
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        if (armed) {
            armed = false;
            (bool ok, bytes memory err) = address(ENDPOINT_V2).call(
                abi.encodeCall(
                    ILayerZeroEndpointV2.lzReceive,
                    (_pending.origin, _pending.receiver, _pending.guid, _pending.message, "")
                )
            );
            lastDeliveryOk = ok;
            lastDeliveryError = err;
            if (ok) ++deliveries;
        }
        return super.redeem(shares_, receiver_, owner_);
    }
}

/// @title StargateComposeNestedDeliveryForkTest
/// @notice IL-9630 (Olympix M40): a compromised allowlisted vault executes the pool's verified token packet from
///         inside the dispatcher's measured balance-delta window, so the in-flight transfer is booked by that delta.
///         The fix caps the later compose credit at the ASSET balance not yet in `trackedIdle`: the compose credits 0,
///         emits `InboundTransferCreditCapped`, still settles with the full pool amount in `TRANSFER_SETTLED`, and the
///         ledger stays equal to the real balance. Everything runs on the REAL LayerZero EndpointV2, the REAL Stargate
///         V2 USDC pools and REAL USDC (Ethereum executor, Arbitrum dispatcher at the same address), and every receipt,
///         including `TRANSFER_SETTLED`, is delivered back to the executor through the real endpoint.
/// @dev Two windows are exercised in one flow (one test per contract, see the fork-isolation rule below):
///      leg 1 = business `REDEEM` (`_redeem` → `_creditRedeemed`, ungated vault call), leg 2 = `UPDATE_VAULTS`
///      removal (`StargateDispatcherLib._reconcileTracked` → `CrosschainVaultActionLib.sweepShares`, gas-capped at
///      `VAULT_SWEEP_GAS`). In each leg the executor bridges an amount with a compose, the token packet is VERIFIED on
///      Arbitrum (the DVN step, as in `StargateForkBase._verify`) but not executed, and the vault executes it from
///      inside `redeem`. The compose then runs through `EndpointV2.lzCompose` and its receipt goes back.
///      Facts that hold with or without a fix are asserted by `_assertNestedDelivery`; the fixed outcome by
///      `_assertCappedCompose` and `_assertLedgerMatchesBalance`. On base 8692fbe5 (before the cap) the compose
///      credited the codec amount again and `trackedIdle` ended 199.877399 / 499.693498 USDC above the balance, so
///      both helpers fail there (regression log `regression-base/T24.log`).
///      Fork isolation: own blocks (Ethereum 26_082_001, Arbitrum 510_000_001), created here instead of
///      `StargateForkBase._createForks`, so no backend is shared with another Stargate fork suite.
///      Needs ETHEREUM_PROVIDER_URL and ARBITRUM_PROVIDER_URL (archive nodes).
contract StargateComposeNestedDeliveryForkTest is StargateForkBase {
    uint256 internal constant OWN_ETHEREUM_FORK_BLOCK = 26_082_001;
    uint256 internal constant OWN_ARBITRUM_FORK_BLOCK = 510_000_001;

    uint256 internal constant SEED_AMOUNT = 1_000e6;
    uint256 internal constant DEPOSIT_AMOUNT = 600e6;
    uint256 internal constant REDEEM_SHARES = 100e6;
    uint256 internal constant IN_FLIGHT_REDEEM_LEG = 200e6;
    uint256 internal constant IN_FLIGHT_SWEEP_LEG = 300e6;

    /// @dev Topic of the dispatcher's `InboundTransferCreditCapped(bytes32,uint256,uint256)` (IL-9630), computed from
    ///      the signature so this file also compiles against the pre-fix base.
    bytes32 internal constant CREDIT_CAPPED_TOPIC = keccak256("InboundTransferCreditCapped(bytes32,uint256,uint256)");

    NestedDeliveryVault internal vault;

    /// @notice Everything one nested-delivery leg measured (USDC: 6 local = 6 shared decimals, so LD == SD).
    struct Leg {
        // Executor (Ethereum) before the send, after the send, after TRANSFER_SETTLED.
        uint256 settledBefore;
        uint256 settledAfter;
        uint256 outboundBefore;
        uint256 outboundWhileInFlight;
        uint256 outboundAfter;
        uint256 anchorBefore;
        uint256 anchorAfter;
        uint256 pendingWhileInFlight;
        uint256 pendingAfter;
        uint64 frontierAfter;
        // The amount the real pool credits (codec amountLD of the compose).
        uint256 creditLD;
        // Dispatcher (Arbitrum): before the window, after the window (nested delivery inside), after the compose.
        uint256 idleBeforeWindow;
        uint256 balanceBeforeWindow;
        uint256 idleAfterWindow;
        uint256 balanceAfterWindow;
        uint256 idleAfterCompose;
        uint256 balanceAfterCompose;
        uint256 sharesBurned;
        uint64 dispatcherVersionAfter;
        // The dispatcher's TRANSFER_SETTLED receipt.
        bytes32 receiptTransferId;
        uint256 receiptAmountSD;
        uint64 receiptVersion;
        // `InboundTransferCreditCapped` events of the compose (count and the last one's fields).
        uint256 capEvents;
        bytes32 capTransferId;
        uint256 capAmountSD;
        uint256 capCreditedSD;
        // Gas of the dispatcher-side lzReceive that carried the nested delivery.
        uint256 windowGas;
    }

    function setUp() public {
        ethereumFork = vm.createFork(vm.envString("ETHEREUM_PROVIDER_URL"), OWN_ETHEREUM_FORK_BLOCK);
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_PROVIDER_URL"), OWN_ARBITRUM_FORK_BLOCK);
        vm.selectFork(ethereumFork);
        vm.warp(COMMON_TIMESTAMP);
        vm.selectFork(arbitrumFork);
        vm.warp(COMMON_TIMESTAMP);
        _deployApps();
        vm.selectFork(arbitrumFork);
        vault = new NestedDeliveryVault{salt: keccak256("IL-9630")}(IERC20(ARBITRUM_USDC), ENDPOINT);
    }

    /// @notice A compromised allowlisted vault executes the verified Stargate token packet inside the dispatcher's
    ///         REDEEM and inside the UPDATE_VAULTS sweep; each time the in-flight amount enters `trackedIdle` through
    ///         the measured delta, and the later compose credits nothing more (capped, event emitted) while the
    ///         executor settles the full pool amount.
    function testForkNestedPoolDeliveryInsideMeasuredWindows() public {
        _bringUp();

        // 1. Ordinary life: bridge a seed amount, settle, allowlist the vault and deposit into it.
        Leg memory seed = _sendAndSettle(SEED_AMOUNT);
        assertEq(seed.idleAfterCompose - seed.idleBeforeWindow, seed.creditLD, "ordinary compose credits in full");
        assertEq(seed.receiptAmountSD, seed.creditLD, "ordinary receipt reports the pool credit");
        assertEq(seed.settledAfter - seed.settledBefore, seed.creditLD, "executor settled the ordinary transfer");
        assertEq(seed.capEvents, 0, "ordinary compose is not capped");
        vm.selectFork(arbitrumFork);
        assertEq(dispatcher.trackedIdle(), _dispatcherUsdc(), "ledger == balance before the attack");

        _updateVaults(_one(address(vault)));
        _relayCommand(_takePacket(APP));
        _sendBusinessCommand(
            BusinessAction.DEPOSIT,
            CrosschainMessages.encodeDepositAction(address(vault), DEPOSIT_AMOUNT, 1)
        );
        _relayCommand(_takePacket(APP));
        vm.selectFork(arbitrumFork);
        assertEq(vault.balanceOf(APP), DEPOSIT_AMOUNT, "position opened in the compromised vault");
        assertEq(dispatcher.trackedIdle(), seed.creditLD - DEPOSIT_AMOUNT, "idle debited by the deposit");
        assertEq(dispatcher.trackedIdle(), _dispatcherUsdc(), "ledger == balance after the deposit");

        // 2. Leg 1: the in-flight transfer lands inside the dispatcher's business REDEEM.
        Leg memory redeemLeg = _nestedLeg(IN_FLIGHT_REDEEM_LEG, false);
        _log("redeem leg", redeemLeg);
        _assertNestedDelivery(redeemLeg, REDEEM_SHARES);
        _assertCappedCompose(redeemLeg);
        _assertLedgerMatchesBalance();

        // 3. Leg 2: the in-flight transfer lands inside the UPDATE_VAULTS sweep that removes the vault (scan path).
        Leg memory sweepLeg = _nestedLeg(IN_FLIGHT_SWEEP_LEG, true);
        _log("sweep leg", sweepLeg);
        _assertNestedDelivery(sweepLeg, DEPOSIT_AMOUNT - REDEEM_SHARES);
        _assertCappedCompose(sweepLeg);
        _assertLedgerMatchesBalance();

        // 4. Both sides agree with the real remote value (all positions are idle USDC now): the executor settled each
        //    transfer once, and the dispatcher's ledger and the observation an attestation reads carry no phantom.
        vm.selectFork(arbitrumFork);
        assertFalse(dispatcher.isTrackedVault(address(vault)), "vault removed and untracked");
        assertEq(vault.balanceOf(APP), 0, "position fully swept");
        uint256 realRemote = _dispatcherUsdc();
        assertEq(dispatcher.trackedIdle(), realRemote, "dispatcher ledger == real remote value");
        assertEq(dispatcher.observation().trackedIdle, realRemote, "observed idle == real remote value");
        vm.selectFork(ethereumFork);
        assertEq(executor.settledRemoteBalance(ARBITRUM_CHAIN_ID), realRemote, "executor settled == real remote value");
        assertEq(executor.outboundInFlight(ARBITRUM_CHAIN_ID), 0, "nothing left in flight");
        assertEq(executor.pendingTransferCount(ARBITRUM_CHAIN_ID), 0, "every pending slot resolved");
    }

    // ---------------------------------------------------------------------
    // Outcome assertions
    // ---------------------------------------------------------------------

    /// @dev Facts of one nested leg that do not depend on the IL-9630 fix: the verified packet was executed by the
    ///      vault from inside the window, the pool's tokens arrived there and were booked by the measured delta, the
    ///      compose moved no tokens, and the receipt round trip closed the executor's transfer.
    function _assertNestedDelivery(Leg memory leg_, uint256 sharesBurned_) internal {
        vm.selectFork(arbitrumFork);
        assertTrue(vault.lastDeliveryOk(), string(vault.lastDeliveryError()));
        assertEq(leg_.sharesBurned, sharesBurned_, "the window redeemed the expected shares");
        // The pool paid the in-flight amount INSIDE the window: the window's balance delta is the 1:1 redemption
        // plus the whole pool credit.
        assertEq(
            leg_.balanceAfterWindow - leg_.balanceBeforeWindow,
            sharesBurned_ + leg_.creditLD,
            "pool tokens arrived inside the measured window"
        );
        // The measured delta booked everything that arrived in the window, the in-flight amount included.
        assertEq(
            leg_.idleAfterWindow - leg_.idleBeforeWindow,
            leg_.balanceAfterWindow - leg_.balanceBeforeWindow,
            "the measured delta credited the in-flight amount"
        );
        assertEq(leg_.balanceAfterCompose, leg_.balanceAfterWindow, "the compose itself moves no tokens");
        // Executor bookkeeping of the transfer: recorded on send, fully removed by the receipt.
        assertEq(leg_.outboundWhileInFlight, leg_.outboundBefore + leg_.creditLD, "outbound recorded on send");
        assertEq(leg_.pendingWhileInFlight, 1, "one pending transfer slot while in flight");
        assertEq(leg_.outboundAfter, leg_.outboundBefore, "TRANSFER_SETTLED removed the whole outbound");
        assertEq(leg_.pendingAfter, 0, "TRANSFER_SETTLED resolved the pending slot");
        assertEq(leg_.receiptVersion, leg_.dispatcherVersionAfter, "receipt carries the settle version");
        assertEq(leg_.frontierAfter, leg_.dispatcherVersionAfter, "executor frontier consumed the settle version");
    }

    /// @dev Fixed outcome (IL-9630): the in-flight amount was already booked by the window's measured delta, so the
    ///      compose credits nothing more and reports the cap through one `InboundTransferCreditCapped(transferId,
    ///      amountSD = pool credit, creditedSD = 0)`. The transfer still settles: the receipt reports the full pool
    ///      amount and the executor's settled bucket and anchor rise by it (the tokens are really on the dispatcher).
    function _assertCappedCompose(Leg memory leg_) internal pure {
        assertEq(leg_.idleAfterCompose, leg_.idleAfterWindow, "compose credited nothing beyond the measured delta");
        assertEq(leg_.capEvents, 1, "one InboundTransferCreditCapped");
        assertEq(leg_.capTransferId, leg_.receiptTransferId, "cap event names the settled transfer");
        assertEq(leg_.capAmountSD, leg_.creditLD, "cap event reports the pool credit");
        assertEq(leg_.capCreditedSD, 0, "cap event reports a zero credit");
        assertEq(leg_.receiptAmountSD, leg_.creditLD, "receipt keeps the full pool amount");
        assertEq(leg_.settledAfter - leg_.settledBefore, leg_.creditLD, "executor settled the pool amount");
        assertEq(leg_.anchorAfter - leg_.anchorBefore, leg_.creditLD, "anchor credited by the pool amount");
    }

    /// @dev Fixed outcome (IL-9630): `trackedIdle` and the observation an attestation reads equal the dispatcher's real
    ///      ASSET balance (USDC: LD == SD), so there is no phantom for an attestation to carry into the source NAV.
    function _assertLedgerMatchesBalance() internal {
        vm.selectFork(arbitrumFork);
        uint256 balance = _dispatcherUsdc();
        uint256 ledger = dispatcher.trackedIdle();
        Observation memory obs = dispatcher.observation();
        emit log_named_uint("dispatcher USDC balance", balance);
        emit log_named_uint("dispatcher trackedIdle", ledger);
        emit log_named_uint("observation().trackedIdle", obs.trackedIdle);
        assertEq(ledger, balance, "trackedIdle == real balance");
        assertEq(obs.trackedIdle, balance, "observed idle == real balance");
    }

    // ---------------------------------------------------------------------
    // Legs
    // ---------------------------------------------------------------------

    /// @dev An ordinary executor -> dispatcher transfer: token delivery, compose, TRANSFER_SETTLED back.
    function _sendAndSettle(uint256 amount_) internal returns (Leg memory leg) {
        Packet memory token = _sendAsset(amount_, leg);
        vm.selectFork(arbitrumFork);
        leg.idleBeforeWindow = dispatcher.trackedIdle();
        leg.balanceBeforeWindow = _dispatcherUsdc();
        _deliver(token, ASSET_SEND_RECEIVE_GAS);
        Compose memory compose = _takeCompose(APP);
        leg.idleAfterWindow = leg.idleBeforeWindow;
        leg.balanceAfterWindow = _dispatcherUsdc();
        _composeAndSettle(compose, leg);
    }

    /// @dev One attack leg. `sweep_` false: the window is a business REDEEM of `REDEEM_SHARES`; true: the window is
    ///      the UPDATE_VAULTS removal of the vault, whose sweep redeems the rest of the position.
    function _nestedLeg(uint256 amount_, bool sweep_) internal returns (Leg memory leg) {
        // Executor bridges `amount_` with a compose; the token packet is VERIFIED on Arbitrum but not executed.
        Packet memory token = _sendAsset(amount_, leg);
        vm.selectFork(arbitrumFork);
        Origin memory tokenOrigin = _verify(token);
        vault.arm(tokenOrigin, token.receiver, token.guid, token.message);
        uint256 sharesBefore = vault.balanceOf(APP);
        leg.idleBeforeWindow = dispatcher.trackedIdle();
        leg.balanceBeforeWindow = _dispatcherUsdc();

        // Executor sends the command whose dispatcher-side execution calls the vault's `redeem`.
        if (sweep_) {
            _updateVaults(new address[](0));
        } else {
            _sendBusinessCommand(
                BusinessAction.REDEEM,
                CrosschainMessages.encodeRedeemAction(address(vault), REDEEM_SHARES, 1)
            );
        }
        Packet memory command = _takePacket(APP);

        // The command runs on Arbitrum; the vault executes the pool packet from inside `redeem`.
        vm.selectFork(arbitrumFork);
        leg.windowGas = _deliver(command, COMMAND_LANE_GAS);
        (Packet memory ack, Compose memory compose) = _takeAckAndCompose();
        leg.idleAfterWindow = dispatcher.trackedIdle();
        leg.balanceAfterWindow = _dispatcherUsdc();
        leg.sharesBurned = sharesBefore - vault.balanceOf(APP);
        _assertAckSucceeded(ack);

        vm.selectFork(ethereumFork);
        _deliver(ack, DISPATCHER_RECEIVE_GAS);
        _composeAndSettle(compose, leg);
    }

    /// @dev Executor-side send; records the executor snapshot before and while in flight and the pool credit.
    function _sendAsset(uint256 amount_, Leg memory leg_) internal returns (Packet memory token) {
        vm.selectFork(ethereumFork);
        leg_.settledBefore = executor.settledRemoteBalance(ARBITRUM_CHAIN_ID);
        leg_.outboundBefore = executor.outboundInFlight(ARBITRUM_CHAIN_ID);
        leg_.anchorBefore = executor.attestationAnchorPrincipal(ARBITRUM_CHAIN_ID);
        deal(ETHEREUM_USDC, APP, amount_);
        leg_.creditLD = _quoteCredit(amount_);
        vm.recordLogs();
        vm.prank(manager);
        executor.sendAssetToDispatcher(ARBITRUM_CHAIN_ID, amount_, leg_.creditLD, _assetSendOptions());
        token = _takeTokenPacket();
        leg_.outboundWhileInFlight = executor.outboundInFlight(ARBITRUM_CHAIN_ID);
        leg_.pendingWhileInFlight = executor.pendingTransferCount(ARBITRUM_CHAIN_ID);
    }

    /// @dev Runs the queued compose on Arbitrum through the real endpoint and delivers its TRANSFER_SETTLED back.
    function _composeAndSettle(Compose memory compose_, Leg memory leg_) internal {
        vm.selectFork(arbitrumFork);
        assertEq(compose_.from, ARBITRUM_STARGATE_USDC, "compose queued by the real pool");
        _compose(compose_, ASSET_SEND_COMPOSE_GAS);
        Packet memory settled = _takeReceiptAndCap(leg_);
        leg_.idleAfterCompose = dispatcher.trackedIdle();
        leg_.balanceAfterCompose = _dispatcherUsdc();
        leg_.dispatcherVersionAfter = dispatcher.stateVersion();
        (MsgType msgType, bytes memory data) = CrosschainMessages.decodeEnvelope(settled.message);
        assertEq(uint8(msgType), uint8(MsgType.TRANSFER_SETTLED), "compose answered with TRANSFER_SETTLED");
        TransferSettled memory receipt = CrosschainMessages.decodeTransferSettled(data);
        leg_.receiptTransferId = receipt.transferId;
        leg_.receiptAmountSD = receipt.amountReceivedSD;
        leg_.receiptVersion = receipt.stateVersion;

        vm.selectFork(ethereumFork);
        _deliver(settled, DISPATCHER_RECEIVE_GAS);
        leg_.settledAfter = executor.settledRemoteBalance(ARBITRUM_CHAIN_ID);
        leg_.outboundAfter = executor.outboundInFlight(ARBITRUM_CHAIN_ID);
        leg_.anchorAfter = executor.attestationAnchorPrincipal(ARBITRUM_CHAIN_ID);
        leg_.pendingAfter = executor.pendingTransferCount(ARBITRUM_CHAIN_ID);
        leg_.frontierAfter = executor.acknowledgedRemoteStateVersion(ARBITRUM_CHAIN_ID);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    /// @dev Manager sends UPDATE_VAULTS on the Ethereum fork; logs are recorded for `_takePacket`.
    function _updateVaults(address[] memory vaults_) internal {
        vm.selectFork(ethereumFork);
        vm.recordLogs();
        vm.prank(manager);
        executor.updatePlasmaVaults(ARBITRUM_CHAIN_ID, vaults_);
    }

    /// @dev Manager sends a business command on the Ethereum fork; logs are recorded for `_takePacket`.
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

    /// @dev Delivers an executor packet on Arbitrum and its (successful) ACK back on Ethereum.
    function _relayCommand(Packet memory command_) internal {
        vm.selectFork(arbitrumFork);
        _deliver(command_, COMMAND_LANE_GAS);
        Packet memory ack = _takePacket(APP);
        _assertAckSucceeded(ack);
        vm.selectFork(ethereumFork);
        _deliver(ack, DISPATCHER_RECEIVE_GAS);
    }

    function _assertAckSucceeded(Packet memory ack_) internal pure {
        (MsgType msgType, bytes memory data) = CrosschainMessages.decodeEnvelope(ack_.message);
        assertEq(uint8(msgType), uint8(MsgType.ACK), "command ACKed");
        CommandAck memory ack = CrosschainMessages.decodeCommandAck(data);
        assertEq(uint8(ack.resolution), uint8(CommandResolution.SUCCEEDED), "command succeeded");
    }

    /// @dev Takes, from the compose's recorded logs, the dispatcher's `TRANSFER_SETTLED` packet and its
    ///      `InboundTransferCreditCapped` events (count and the last one's fields into `leg_`).
    function _takeReceiptAndCap(Leg memory leg_) internal returns (Packet memory settled) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == APP && logs[i].topics[0] == CREDIT_CAPPED_TOPIC) {
                ++leg_.capEvents;
                (leg_.capTransferId, leg_.capAmountSD, leg_.capCreditedSD) = abi.decode(
                    logs[i].data,
                    (bytes32, uint256, uint256)
                );
            } else if (logs[i].emitter == LZ_ENDPOINT && logs[i].topics[0] == PACKET_SENT_TOPIC) {
                (bytes memory encoded, , ) = abi.decode(logs[i].data, (bytes, bytes, address));
                Packet memory candidate = this.decodePacket(encoded);
                if (address(uint160(uint256(candidate.origin.sender))) == APP) {
                    settled = candidate;
                    found = true;
                }
            }
        }
        require(found, "fork: no receipt from the dispatcher");
    }

    /// @dev Takes, from ONE set of recorded logs, the dispatcher's receipt packet and the compose the nested pool
    ///      delivery queued for `APP` (both are emitted by the same dispatcher-side `lzReceive`).
    function _takeAckAndCompose() internal returns (Packet memory ack, Compose memory compose) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundAck;
        bool foundCompose;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != LZ_ENDPOINT) continue;
            if (logs[i].topics[0] == PACKET_SENT_TOPIC) {
                (bytes memory encoded, , ) = abi.decode(logs[i].data, (bytes, bytes, address));
                Packet memory candidate = this.decodePacket(encoded);
                if (address(uint160(uint256(candidate.origin.sender))) == APP) {
                    ack = candidate;
                    foundAck = true;
                }
            } else if (logs[i].topics[0] == COMPOSE_SENT_TOPIC) {
                (address from, address to, bytes32 guid, uint16 index, bytes memory message) = abi.decode(
                    logs[i].data,
                    (address, address, bytes32, uint16, bytes)
                );
                if (to == APP) {
                    compose = Compose({from: from, to: to, guid: guid, index: index, message: message});
                    foundCompose = true;
                }
            }
        }
        require(foundAck, "fork: no receipt from the dispatcher");
        require(foundCompose, "fork: the nested pool delivery queued no compose");
    }

    function _quoteCredit(uint256 amount_) internal view returns (uint256) {
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
        return receipt.amountReceivedLD;
    }

    function _dispatcherUsdc() internal view returns (uint256) {
        return IERC20(ARBITRUM_USDC).balanceOf(APP);
    }

    function _one(address vault_) internal pure returns (address[] memory vaults) {
        vaults = new address[](1);
        vaults[0] = vault_;
    }

    function _log(string memory label_, Leg memory leg_) internal {
        emit log(label_);
        emit log_named_uint("  pool credit (codec amountLD)", leg_.creditLD);
        emit log_named_uint("  dispatcher lzReceive gas (window)", leg_.windowGas);
        emit log_named_uint("  trackedIdle before window", leg_.idleBeforeWindow);
        emit log_named_uint("  USDC balance before window", leg_.balanceBeforeWindow);
        emit log_named_uint("  trackedIdle after window", leg_.idleAfterWindow);
        emit log_named_uint("  USDC balance after window", leg_.balanceAfterWindow);
        emit log_named_uint("  trackedIdle after compose", leg_.idleAfterCompose);
        emit log_named_uint("  USDC balance after compose", leg_.balanceAfterCompose);
        emit log_named_uint("  receipt amountReceivedSD", leg_.receiptAmountSD);
        emit log_named_uint("  InboundTransferCreditCapped events", leg_.capEvents);
        emit log_named_uint("  cap event amountSD", leg_.capAmountSD);
        emit log_named_uint("  cap event creditedSD", leg_.capCreditedSD);
        emit log_named_uint("  executor settled before", leg_.settledBefore);
        emit log_named_uint("  executor settled after", leg_.settledAfter);
        emit log_named_uint("  executor outbound while in flight", leg_.outboundWhileInFlight);
        emit log_named_uint("  executor outbound after", leg_.outboundAfter);
        emit log_named_uint("  executor anchor before", leg_.anchorBefore);
        emit log_named_uint("  executor anchor after", leg_.anchorAfter);
    }
}
