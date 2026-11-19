// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {BusinessAction, CommandStatus, MsgType} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer,
    TransferSettled,
    SweepFloor
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemoteVault} from "./mocks/MockRemoteVault.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title WindowDeliveryVault
/// @notice Allowlisted ERC-4626 that, once armed, pays `armedAmount` of ASSET to the redeem receiver (the dispatcher)
///         from inside `redeem`: the unit stand-in for a Stargate pool delivery executed inside the dispatcher's
///         measured balance-delta window (IL-9630). The real-endpoint version is
///         `StargateComposeNestedDeliveryForkTest`.
contract WindowDeliveryVault is MockRemoteVault {
    MockERC20 public immutable TOKEN;
    uint256 public armedAmount;

    constructor(MockERC20 token_) MockRemoteVault(IERC20(address(token_)), "Window Vault", "WIN") {
        TOKEN = token_;
    }

    function arm(uint256 amount_) external {
        armedAmount = amount_;
    }

    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256) {
        uint256 amount = armedAmount;
        if (amount != 0) {
            armedAmount = 0;
            TOKEN.mint(receiver_, amount);
        }
        return super.redeem(shares_, receiver_, owner_);
    }
}

/// @title StargateComposeCreditCapTest
/// @notice IL-9630 (Olympix M40): `StargateCrosschainDispatcher._handleCompose` credits
///         `min(amountSD, _toSD(ASSET balance) - trackedIdle)` (0 when the balance in SD is below the ledger), never
///         reverts, still settles the transfer (flag, state version, receipt with the FULL codec amount), and emits
///         `InboundTransferCreditCapped(transferId, amountSD, creditedSD)` only when the cap binds. Cases: ordinary
///         compose (full credit, no event), delivery already booked by a measured window (zero credit), window plus a
///         smaller donation (partial credit), window plus a covering donation (full credit, no event), duplicate
///         compose (idempotent), and an 18/6 asset (balance dust does not enter the credit, one missing wei cuts one SD
///         unit). The capped cases fail on base 8692fbe5, which credited the codec amount unconditionally.
/// @dev New symbols are matched by event topic, so the file also compiles against the pre-fix base.
contract StargateComposeCreditCapTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    bytes32 internal constant GUID = keccak256("guid");
    bytes32 internal constant TRANSFER = keccak256("in-flight transfer");

    bytes32 internal constant CREDIT_CAPPED_TOPIC = keccak256("InboundTransferCreditCapped(bytes32,uint256,uint256)");
    bytes32 internal constant SETTLED_TOPIC = keccak256("InboundTransferSettled(bytes32,uint256,uint64)");

    /// @dev Events the dispatcher emitted during one compose delivery.
    struct ComposeLogs {
        uint256 capEvents;
        bytes32 capTransferId;
        uint256 capAmountSD;
        uint256 capCreditedSD;
        uint256 settledEvents;
        uint256 settledAmountSD;
    }

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal token;
    WindowDeliveryVault internal vault;
    StargateCrosschainDispatcher internal dispatcher;
    /// @dev Local units per shared unit (1 for 6/6, 1e12 for 18/6).
    uint256 internal rate;

    function setUp() public {
        vm.chainId(42161);
        vm.warp(365 days);
        endpoint = new MockLzEndpoint();
    }

    // ---------------------------------------------------------------------
    // 6 / 6 asset
    // ---------------------------------------------------------------------

    function testShouldCreditFullAmountOnOrdinaryCompose() public {
        _deploy(6);
        token.mint(address(dispatcher), 100e6);

        ComposeLogs memory logs = _compose(TRANSFER, 100e6);

        assertEq(dispatcher.trackedIdle(), 100e6, "full codec amount credited");
        assertEq(logs.capEvents, 0, "no InboundTransferCreditCapped on the honest path");
        _assertSettled(logs, 100e6, 1);
    }

    function testShouldCreditZeroWhenDeliveryWasBookedInWindow() public {
        _deploy(6);
        _bookInWindow(50e6, 30e6);
        assertEq(dispatcher.trackedIdle(), 80e6, "window booked the redemption and the in-flight amount");
        assertEq(_balance(), 80e6, "ledger == balance after the window");
        uint64 versionBefore = dispatcher.stateVersion();

        ComposeLogs memory logs = _compose(TRANSFER, 30e6);

        assertEq(dispatcher.trackedIdle(), 80e6, "compose credited nothing: already booked");
        assertEq(dispatcher.trackedIdle(), _balance(), "ledger == balance");
        _assertCapped(logs, 30e6, 0);
        _assertSettled(logs, 30e6, versionBefore + 1);

        // A duplicate of the capped compose is a no-op even when unbooked tokens are present.
        token.mint(address(dispatcher), 30e6);
        uint256 sentBefore = endpoint.sentCount();
        ComposeLogs memory again = _compose(TRANSFER, 30e6);
        assertEq(dispatcher.trackedIdle(), 80e6, "duplicate credits nothing");
        assertEq(again.capEvents, 0, "duplicate emits no cap event");
        assertEq(again.settledEvents, 0, "duplicate emits no settle event");
        assertEq(dispatcher.stateVersion(), versionBefore + 1, "duplicate does not bump the state version");
        assertEq(endpoint.sentCount(), sentBefore, "duplicate sends no receipt");
    }

    function testShouldCreditPartiallyUpToUnbookedBalance() public {
        _deploy(6);
        _bookInWindow(50e6, 30e6);
        token.mint(address(dispatcher), 10e6); // unbooked donation, smaller than the transfer
        uint64 versionBefore = dispatcher.stateVersion();

        ComposeLogs memory logs = _compose(TRANSFER, 30e6);

        assertEq(dispatcher.trackedIdle(), 90e6, "only the unbooked 10e6 credited");
        assertEq(dispatcher.trackedIdle(), _balance(), "ledger == balance");
        _assertCapped(logs, 30e6, 10e6);
        _assertSettled(logs, 30e6, versionBefore + 1);
    }

    function testShouldCreditFullAmountWhenUnbookedBalanceCoversIt() public {
        _deploy(6);
        _bookInWindow(50e6, 30e6);
        token.mint(address(dispatcher), 40e6); // unbooked donation, larger than the transfer
        uint64 versionBefore = dispatcher.stateVersion();

        ComposeLogs memory logs = _compose(TRANSFER, 30e6);

        // The cap is slack, but the extra credit is backed by real tokens: the ledger never exceeds the balance.
        assertEq(dispatcher.trackedIdle(), 110e6, "full codec amount credited");
        assertEq(_balance() - dispatcher.trackedIdle(), 10e6, "the rest of the donation stays unbooked");
        assertEq(logs.capEvents, 0, "cap did not bind: no event");
        _assertSettled(logs, 30e6, versionBefore + 1);
    }

    function testShouldIgnoreDuplicateOrdinaryCompose() public {
        _deploy(6);
        token.mint(address(dispatcher), 100e6);
        _compose(TRANSFER, 100e6);
        token.mint(address(dispatcher), 100e6); // tokens of a second delivery, same transfer id
        uint64 versionBefore = dispatcher.stateVersion();
        uint256 sentBefore = endpoint.sentCount();

        ComposeLogs memory logs = _compose(TRANSFER, 100e6);

        assertEq(dispatcher.trackedIdle(), 100e6, "no second credit");
        assertEq(logs.capEvents, 0, "no cap event");
        assertEq(logs.settledEvents, 0, "no settle event");
        assertEq(dispatcher.stateVersion(), versionBefore, "state version unchanged");
        assertEq(endpoint.sentCount(), sentBefore, "no second receipt");
    }

    // ---------------------------------------------------------------------
    // 18 / 6 asset (LD = SD * 1e12)
    // ---------------------------------------------------------------------

    function testShouldCreditFullAmountWithBalanceDustOnEighteenDecimals() public {
        _deploy(18);
        token.mint(address(dispatcher), 100e18 + 1e12 - 1); // one SD unit minus one wei of dust on top

        ComposeLogs memory logs = _compose(TRANSFER, 100e18);

        assertEq(dispatcher.trackedIdle(), 100e6, "full codec amount credited, dust ignored");
        assertEq(logs.capEvents, 0, "no cap event");
        _assertSettled(logs, 100e6, 1);
    }

    function testShouldNotCreditBalanceDustOnEighteenDecimals() public {
        _deploy(18);
        _bookInWindow(50e18, 30e18);
        assertEq(dispatcher.trackedIdle(), 80e6, "window booked 80 SD");
        token.mint(address(dispatcher), 10e18 + 1e12 - 1); // 10 SD unbooked plus sub-SD dust
        uint64 versionBefore = dispatcher.stateVersion();

        ComposeLogs memory logs = _compose(TRANSFER, 30e18);

        assertEq(dispatcher.trackedIdle(), 90e6, "credit floored to whole SD units: dust not credited");
        assertEq(_balance() - dispatcher.trackedIdle() * rate, 1e12 - 1, "only the dust stays unbooked");
        _assertCapped(logs, 30e6, 10e6);
        _assertSettled(logs, 30e6, versionBefore + 1);
    }

    function testShouldCutOneSharedUnitWhenOneWeiIsMissingOnEighteenDecimals() public {
        _deploy(18);
        token.mint(address(dispatcher), 100e18 - 1);

        ComposeLogs memory logs = _compose(TRANSFER, 100e18);

        assertEq(dispatcher.trackedIdle(), 100e6 - 1, "one SD unit cut");
        assertLe(dispatcher.trackedIdle() * rate, _balance(), "ledger (LD) within the balance");
        _assertCapped(logs, 100e6, 100e6 - 1);
        _assertSettled(logs, 100e6, 1);
    }

    // ---------------------------------------------------------------------
    // Assertions
    // ---------------------------------------------------------------------

    function _assertCapped(ComposeLogs memory logs_, uint256 amountSD_, uint256 creditedSD_) internal pure {
        assertEq(logs_.capEvents, 1, "one InboundTransferCreditCapped");
        assertEq(logs_.capTransferId, TRANSFER, "cap event names the transfer");
        assertEq(logs_.capAmountSD, amountSD_, "cap event reports the codec amount");
        assertEq(logs_.capCreditedSD, creditedSD_, "cap event reports the credited amount");
    }

    /// @dev The transfer settled once with the FULL codec amount: flag, state version, settle event, receipt.
    function _assertSettled(ComposeLogs memory logs_, uint256 amountSD_, uint64 version_) internal view {
        assertTrue(dispatcher.transferSettled(TRANSFER), "transfer marked settled");
        assertEq(dispatcher.stateVersion(), version_, "state version bumped once");
        assertEq(logs_.settledEvents, 1, "one InboundTransferSettled");
        assertEq(logs_.settledAmountSD, amountSD_, "settle event reports the codec amount");
        (MsgType msgType, bytes memory data) = CrosschainMessages.decodeEnvelope(endpoint.lastMessage());
        assertEq(uint8(msgType), uint8(MsgType.TRANSFER_SETTLED), "TRANSFER_SETTLED sent");
        TransferSettled memory receipt = CrosschainMessages.decodeTransferSettled(data);
        assertEq(receipt.transferId, TRANSFER, "receipt names the transfer");
        assertEq(receipt.amountReceivedSD, amountSD_, "receipt keeps the full codec amount");
        assertEq(receipt.stateVersion, version_, "receipt carries the settle version");
    }

    // ---------------------------------------------------------------------
    // Setup and flows
    // ---------------------------------------------------------------------

    function _deploy(uint8 decimals_) internal {
        token = new MockERC20("Token", "TKN", decimals_);
        pool = new MockStargatePool(address(token), 6);
        rate = 10 ** (decimals_ - 6);
        vault = new WindowDeliveryVault(token);

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 1,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0).addExecutorLzComposeOption(
                0,
                1_500_000,
                0
            )
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(token),
            address(pool),
            keccak256("TKN"),
            address(0xF),
            address(0xADADAD),
            address(0x6A6A6A),
            uint256(3 days),
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);
    }

    /// @dev Credits `positionLD_` through an ordinary compose, allowlists the window vault, deposits it all, then
    ///      REDEEMs the whole position while the vault pays `deliveredLD_` (the in-flight transfer) to the dispatcher
    ///      inside `redeem`, so the measured delta books both. Uses sequences 0..2; only the seed compose bumps the
    ///      state version (commands are value-neutral).
    function _bookInWindow(uint256 positionLD_, uint256 deliveredLD_) internal {
        token.mint(address(dispatcher), positionLD_);
        _compose(keccak256("seed"), positionLD_);

        address[] memory vaults = new address[](1);
        vaults[0] = address(vault);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({
                    commandId: keccak256("uv"),
                    sequence: 0,
                    newConfigEpoch: 1,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    vaults: vaults,
                    floors: new SweepFloor[](0)
                })
            )
        );
        _command(
            keccak256("dep"),
            1,
            BusinessAction.DEPOSIT,
            CrosschainMessages.encodeDepositAction(address(vault), positionLD_ / rate, 0)
        );
        assertEq(dispatcher.trackedIdle(), 0, "whole idle deposited");

        vault.arm(deliveredLD_);
        _command(
            keccak256("red"),
            2,
            BusinessAction.REDEEM,
            CrosschainMessages.encodeRedeemAction(address(vault), vault.balanceOf(address(dispatcher)), 0)
        );
        assertEq(vault.armedAmount(), 0, "the in-flight amount was paid inside the window");
        assertEq(vault.balanceOf(address(dispatcher)), 0, "position redeemed");
    }

    /// @dev Delivers the authenticated compose of `transferId_` for `amountLD_` (no tokens minted here) and returns
    ///      the dispatcher's events from that delivery.
    function _compose(bytes32 transferId_, uint256 amountLD_) internal returns (ComposeLogs memory logs) {
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        vm.recordLogs();
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
        Vm.Log[] memory entries = vm.getRecordedLogs();
        for (uint256 i; i < entries.length; ++i) {
            if (entries[i].emitter != address(dispatcher)) continue;
            if (entries[i].topics[0] == CREDIT_CAPPED_TOPIC) {
                ++logs.capEvents;
                (logs.capTransferId, logs.capAmountSD, logs.capCreditedSD) = abi.decode(
                    entries[i].data,
                    (bytes32, uint256, uint256)
                );
            } else if (entries[i].topics[0] == SETTLED_TOPIC) {
                ++logs.settledEvents;
                (, logs.settledAmountSD, ) = abi.decode(entries[i].data, (bytes32, uint256, uint64));
            }
        }
    }

    function _command(bytes32 commandId_, uint64 sequence_, BusinessAction action_, bytes memory data_) internal {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: commandId_,
                    sequence: sequence_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(action_),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: data_
                })
            )
        );
        assertEq(uint8(dispatcher.commandStatus(commandId_)), uint8(CommandStatus.SUCCEEDED), "command succeeded");
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher),
            EXECUTOR_EID,
            bytes32(uint256(uint160(address(dispatcher)))),
            GUID,
            envelope_
        );
    }

    function _balance() internal view returns (uint256) {
        return token.balanceOf(address(dispatcher));
    }
}
