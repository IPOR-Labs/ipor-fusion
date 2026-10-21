// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OptionsBuilder} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/libs/OptionsBuilder.sol";
import {EnforcedOptionParam} from "@layerzerolabs/lz-evm-oapp-v2/contracts/oapp/interfaces/IOAppOptionsType3.sol";

import {StargateCrosschainDispatcher} from "../../contracts/crosschain/stargate/StargateCrosschainDispatcher.sol";
import {Observation} from "../../contracts/crosschain/interfaces/ICrosschainDispatcher.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {
    CrosschainMessages,
    Command,
    UpdateVaults,
    OutboundTransfer,
    ReturnAssetsRequest
} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {RescueModule} from "../../contracts/crosschain/lib/RescueModule.sol";

import {MockLzEndpoint} from "./mocks/MockLzEndpoint.sol";
import {MockStargatePool, LzComposeBuilder} from "./mocks/MockStargatePool.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockFaultyVault, TrackedVaultPricingHarness} from "./mocks/MockFaultyVault.sol";
import {TrackedVaultPricingLib} from "../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";
import {DEFAULT_COMMAND_BUDGET} from "./CommandBudget.sol";

/// @title StargateUnpricedVaultTest
/// @notice IL-8602 (Ackee TP-M-24): one faulty tracked vault must not revert the dispatcher's aggregate view, must
///         not block the settle / recall paths, and a permanently unpriceable vault can be written off after the
///         rescue timelock.
contract StargateUnpricedVaultTest is Test {
    using OptionsBuilder for bytes;

    uint256 internal constant DISPATCHER_CHAIN = 42161;
    uint256 internal constant EXECUTOR_CHAIN = 1;
    uint32 internal constant EXECUTOR_EID = 30101;
    uint256 internal constant RESCUE_DELAY = 3 days;
    bytes32 internal constant GUID = keccak256("guid");

    event TrackedVaultWrittenOff(address vault, uint256 sharesLeft);

    address internal admin = address(0xADADAD);
    address internal guardian = address(0x6A6A6A);

    MockLzEndpoint internal endpoint;
    MockStargatePool internal pool;
    MockERC20 internal usdc;
    MockFaultyVault internal vaultA;
    MockFaultyVault internal vaultB;
    StargateCrosschainDispatcher internal dispatcher;

    function setUp() public {
        vm.chainId(DISPATCHER_CHAIN);
        vm.warp(365 days);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        pool = new MockStargatePool(address(usdc), 6);
        endpoint = new MockLzEndpoint();
        vaultA = new MockFaultyVault(IERC20(address(usdc)), "A", "A");
        vaultB = new MockFaultyVault(IERC20(address(usdc)), "B", "B");

        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](2);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: EXECUTOR_EID, msgType: 1, options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(2_000_000, 0)
        });
        enforcedOptions[1] = EnforcedOptionParam({
            eid: EXECUTOR_EID,
            msgType: 2,
            options: OptionsBuilder.newOptions().addExecutorLzReceiveOption(250_000, 0)
                .addExecutorLzComposeOption(0, 1_500_000, 0)
        });
        bytes memory args = abi.encode(
            address(endpoint),
            address(usdc),
            address(pool),
            keccak256("USDC"),
            address(0xF),
            admin,
            guardian,
            RESCUE_DELAY,
            EXECUTOR_CHAIN,
            EXECUTOR_EID,
            abi.encode(enforcedOptions)
        );
        dispatcher = StargateCrosschainDispatcher(
            payable(vm.deployCode("StargateCrosschainDispatcher.sol:StargateCrosschainDispatcher", args))
        );
        vm.deal(address(dispatcher), 100 ether);

        address[] memory vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        _deliver(
            CrosschainMessages.encodeUpdateVaults(
                UpdateVaults({commandId: keccak256("uv"), sequence: 0, newConfigEpoch: 1, minExecutionGas: DEFAULT_COMMAND_BUDGET, vaults: vaults})
            )
        );
        _compose(keccak256("t1"), 100e6);
        _deposit(keccak256("depA"), 1, address(vaultA), 50e6);
        _deposit(keccak256("depB"), 2, address(vaultB), 30e6);
    }

    function _deliver(bytes memory envelope_) internal {
        endpoint.deliverLz(
            address(dispatcher), EXECUTOR_EID, bytes32(uint256(uint160(address(dispatcher)))), GUID, envelope_
        );
    }

    function _deposit(bytes32 id_, uint64 seq_, address vault_, uint256 amountSD_) internal {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id_,
                    sequence: seq_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: uint8(BusinessAction.DEPOSIT),
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: CrosschainMessages.encodeDepositAction(vault_, amountSD_, 0)
                })
            )
        );
    }

    function _compose(bytes32 transferId_, uint256 amountLD_) internal {
        usdc.mint(address(dispatcher), amountLD_);
        bytes memory envelope = CrosschainMessages.encodeOutboundTransfer(OutboundTransfer({transferId: transferId_}));
        bytes memory composeMsg = LzComposeBuilder.build(address(dispatcher), EXECUTOR_EID, amountLD_, envelope);
        endpoint.deliverCompose(address(dispatcher), address(pool), GUID, composeMsg);
    }

    function _breakA() internal {
        vaultA.setFaults(true, false, false);
    }

    function testShouldPriceRemainingVaultsWhenOneReverts() public {
        Observation memory healthy = dispatcher.observation();
        assertEq(healthy.unpricedCount, 0, "healthy: nothing unpriced");
        assertTrue(healthy.vaultValued[0] && healthy.vaultValued[1], "healthy: all valued");
        assertEq(healthy.vaultAssetValues[0], 50e6, "A priced");

        _breakA();
        Observation memory obs = dispatcher.observation();
        assertEq(obs.trackedVaults.length, 2, "broken vault stays in the set");
        assertEq(obs.unpricedCount, 1, "one unpriced");
        assertFalse(obs.vaultValued[0], "A flagged");
        assertTrue(obs.vaultValued[1], "B priced");
        assertEq(obs.vaultAssetValues[0], 0, "A contributes nothing");
        assertEq(obs.vaultAssetValues[1], 30e6, "B value intact");
        assertEq(obs.trackedIdle, 20e6, "idle intact");
    }

    function testShouldFlagVaultWhenConvertToAssetsRevertsOrReturnsShortData() public {
        vaultA.setFaults(false, true, false);
        assertEq(dispatcher.observation().unpricedCount, 1, "convertToAssets revert flagged");
        vaultA.setFaults(false, false, true);
        assertEq(dispatcher.observation().unpricedCount, 1, "short return flagged");
    }

    /// @dev Behaviour pin: the Stargate settle path never reads vaults, so this holds with or without IL-8602.
    function testShouldStillSettleInboundTransferWhenVaultReverts() public {
        _breakA();
        _compose(keccak256("t2"), 10e6);
        assertTrue(dispatcher.transferSettled(keccak256("t2")), "settled");
        assertEq(dispatcher.trackedIdle(), 30e6, "idle credited");
        assertEq(dispatcher.observation().unpricedCount, 1, "still flagged");
    }

    /// @dev Behaviour pin: the Stargate recall path never reads vaults, so this holds with or without IL-8602.
    function testShouldStillAnswerRecallWhenVaultReverts() public {
        _breakA();
        _deliver(
            CrosschainMessages.encodeReturnAssetsRequest(
                ReturnAssetsRequest({
                    requestId: keccak256("r1"), amountSD: 15e6, maxAccountedSD: 15e6, minReturnSD: 0
                })
            )
        );
        assertTrue(dispatcher.recallConsumed(keccak256("r1")), "recall consumed");
        assertEq(dispatcher.trackedIdle(), 5e6, "idle debited by the returned amount");
    }

    function testShouldPriceOthersWhenOneVaultBurnsGas() public {
        vaultA.setExtraFaults(false, true);
        Observation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 1, "burner flagged");
        assertFalse(obs.vaultValued[0], "A flagged");
        assertTrue(obs.vaultValued[1], "B priced");
        assertEq(obs.vaultAssetValues[1], 30e6, "B value intact");
    }

    function testShouldRevertWhenCallerGasCannotCoverVaultRead() public {
        vm.expectRevert(TrackedVaultPricingLib.InsufficientGasForVaultRead.selector);
        dispatcher.observation{gas: 150_000}();

        TrackedVaultPricingHarness harness = new TrackedVaultPricingHarness();
        vm.expectRevert(TrackedVaultPricingLib.InsufficientGasForVaultRead.selector);
        harness.read{gas: 150_000}(address(vaultA), address(dispatcher));
    }

    // ------------------------------------------------------------------ IL-8645: asset() drift

    function _command(bytes32 id_, uint64 seq_, uint8 action_, bytes memory actionData_) internal {
        _deliver(
            CrosschainMessages.encodeCommand(
                Command({
                    commandId: id_,
                    sequence: seq_,
                    commandConfigEpoch: dispatcher.commandConfigEpoch(),
                    action: action_,
                    minExecutionGas: DEFAULT_COMMAND_BUDGET,
                    actionData: actionData_
                })
            )
        );
    }

    event CommandFailed(bytes32 commandId, uint64 sequence);

    function testShouldNackDepositWhenVaultAssetDrifted() public {
        vaultA.setDriftedAsset(address(new MockERC20("Other", "OTH", 6)));
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit CommandFailed(keccak256("depDrift"), 3);
        _deposit(keccak256("depDrift"), 3, address(vaultA), 10e6);
        assertEq(uint8(dispatcher.commandStatus(keccak256("depDrift"))), uint8(CommandStatus.FAILED), "NACKed");
        assertEq(dispatcher.nextCommandSequence(), 3, "sequence not advanced");
        assertEq(dispatcher.trackedIdle(), 20e6, "idle untouched");
        assertEq(usdc.allowance(address(dispatcher), address(vaultA)), 0, "nothing approved");
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e6, "no new shares");
    }

    /// @dev Stargate keeps the locked Observation shape: `vaultValued[i] == false` is the only signal (no reason code).
    function testShouldFlagDriftedAssetVaultAsUnpriced() public {
        vaultA.setDriftedAsset(address(new MockERC20("Other", "OTH", 6)));
        Observation memory obs = dispatcher.observation();
        assertEq(obs.unpricedCount, 1, "drifted vault unpriced");
        assertFalse(obs.vaultValued[0], "A flagged");
        assertEq(obs.vaultAssetValues[0], 0, "A contributes nothing");
        assertTrue(obs.vaultValued[1], "B priced");
        assertEq(obs.vaultAssetValues[1], 30e6, "B value intact");

        vaultA.setDriftedAsset(address(0));
        vaultA.setExtraFaults(true, false); // asset() reverts
        obs = dispatcher.observation();
        assertFalse(obs.vaultValued[0], "reverting asset() flagged too");
        assertEq(obs.unpricedCount, 1, "one unpriced");
    }

    function testShouldStillRedeemFromDriftedVault() public {
        vaultA.setDriftedAsset(address(new MockERC20("Other", "OTH", 6)));
        _command(
            keccak256("redDrift"),
            3,
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(vaultA), 50e6, 0)
        );
        assertEq(uint8(dispatcher.commandStatus(keccak256("redDrift"))), uint8(CommandStatus.SUCCEEDED), "redeemed");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "position exited");
        assertEq(dispatcher.trackedIdle(), 70e6, "idle credited");
    }

    function testShouldNotFlagEmptyPositionOfDriftedVault() public {
        vaultA.setDriftedAsset(address(new MockERC20("Other", "OTH", 6)));
        // Zero the balance without a REDEEM: a full redeem would untrack the vault and the pricing loop would never
        // reach the zero-shares skip.
        deal(address(vaultA), address(dispatcher), 0, true);
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "no shares");
        assertEq(dispatcher.observation().unpricedCount, 0, "empty drifted position is worth zero, not unpriced");
    }

    function testShouldForceUntrackAfterTimelock() public {
        _breakA();
        vm.prank(admin);
        uint256 id = dispatcher.scheduleForceUntrack(address(vaultA));

        // Too early.
        vm.prank(admin);
        vm.expectPartialRevert(RescueModule.RescueTimelockNotElapsed.selector);
        dispatcher.executeForceUntrack(id, address(vaultA));

        // Guardian veto path: a cancelled write-off cannot execute.
        vm.prank(guardian);
        dispatcher.cancelRescue(id);
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.prank(admin);
        vm.expectPartialRevert(RescueModule.RescueNotScheduled.selector);
        dispatcher.executeForceUntrack(id, address(vaultA));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "still tracked after veto");

        // Fresh schedule, executes after the delay.
        vm.prank(admin);
        id = dispatcher.scheduleForceUntrack(address(vaultA));
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultWrittenOff(address(vaultA), 0); // balanceOf is unreadable -> reported as 0
        vm.prank(admin);
        dispatcher.executeForceUntrack(id, address(vaultA));

        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "A no longer tracked");
        Observation memory obs = dispatcher.observation();
        assertEq(obs.trackedVaults.length, 1, "set shrank");
        assertEq(obs.trackedVaults[0], address(vaultB), "B remains");
        assertEq(obs.unpricedCount, 0, "observation healthy again");

        // The id is single-use.
        vm.prank(admin);
        vm.expectPartialRevert(RescueModule.RescueAlreadyConsumed.selector);
        dispatcher.executeForceUntrack(id, address(vaultA));
    }

    function testShouldReportSharesLeftOnWriteOffWhenBalanceReadable() public {
        vaultA.setFaults(false, true, false); // only convertToAssets is broken
        vm.prank(admin);
        uint256 id = dispatcher.scheduleForceUntrack(address(vaultA));
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultWrittenOff(address(vaultA), 50e6);
        vm.prank(admin);
        dispatcher.executeForceUntrack(id, address(vaultA));
        assertEq(vaultA.balanceOf(address(dispatcher)), 50e6, "shares stay in the dispatcher");
    }

    function testShouldRejectForceUntrackByNonAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        dispatcher.scheduleForceUntrack(address(vaultA));

        vm.prank(admin);
        uint256 id = dispatcher.scheduleForceUntrack(address(vaultA));
        vm.warp(block.timestamp + RESCUE_DELAY);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.UnauthorizedRescueAdmin.selector, address(this)));
        dispatcher.executeForceUntrack(id, address(vaultA));
    }

    function testShouldRejectForceUntrackOfUntrackedVault() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(CrosschainErrors.VaultNotTracked.selector, address(0xBEEF)));
        dispatcher.scheduleForceUntrack(address(0xBEEF));
    }
}
