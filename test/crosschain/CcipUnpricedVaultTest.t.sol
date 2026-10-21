// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ValueNeutralToken} from "./CcipValueNeutralVersionTest.t.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher, CcipObservation} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockFaultyVault, TrackedVaultPricingHarness} from "./mocks/MockFaultyVault.sol";
import {TrackedVaultPricingLib} from "../../contracts/crosschain/lib/TrackedVaultPricingLib.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";

/// @title CcipUnpricedVaultTest
/// @notice IL-8602 (Ackee TP-M-24): one faulty tracked vault must not revert the dispatcher's valuation, which also
///         feeds every response (TRANSFER_SETTLED, RETURN_TRANSFER, ...). The failure is surfaced through
///         `observation().unpricedCount` and `TrackedVaultUnpriced`; a permanently unpriceable vault is untracked when
///         it is removed from the allowlist (IL-8784).
contract CcipUnpricedVaultTest is Test {
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 5009297550715157269;
    uint64 internal constant DISPATCHER_SELECTOR = 15971525489660198786;
    address internal constant RESCUE_ADMIN = address(0xA11);
    address internal constant GUARDIAN = address(0xB22);
    address internal constant APPROVER = address(0xA33);
    uint256 internal constant RESCUE_DELAY = 3 days;

    event TrackedVaultUnpriced(address vault, uint8 reason);
    event CommandFailed(bytes32 commandId, uint64 sequence);
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    MockCcipRouter internal router;
    ValueNeutralToken internal token;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    MockFaultyVault internal vaultA;
    MockFaultyVault internal vaultB;
    address internal factory;

    function setUp() public {
        router = new MockCcipRouter();
        token = new ValueNeutralToken();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            _safety()
        );
        CcipRouteConfig memory back = CcipRouteConfig({
            chainSelector: EXECUTOR_SELECTOR,
            peer: address(executor),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            back,
            RESCUE_ADMIN,
            GUARDIAN,
            RESCUE_DELAY
        );
        vaultA = new MockFaultyVault(IERC20(address(token)), "A", "A");
        vaultB = new MockFaultyVault(IERC20(address(token)), "B", "B");
        address[] memory vaults = new address[](2);
        vaults[0] = address(vaultA);
        vaults[1] = address(vaultB);
        vm.prank(factory);
        dispatcher.configureVaults(vaults, true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        vm.warp(1_700_000_000);
        vm.roll(1_000);
    }

    function _safety() private view returns (CcipCrosschainExecutor.SafetyConfig memory) {
        return
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
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

    // ------------------------------------------------------------------ helpers

    function _bridge(uint256 amount_) private {
        token.mint(address(executor), amount_);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, amount_, 0, address(0), 2_000_000);
    }

    /// @dev Gives the dispatcher a position without going through the command lane.
    function _position(MockFaultyVault vault_, uint256 amount_) private {
        token.mint(address(this), amount_);
        token.approve(address(vault_), amount_);
        vault_.deposit(amount_, address(dispatcher));
    }

    function testShouldPriceRemainingVaultsWhenOneReverts() public {
        _position(vaultA, 50e18);
        _position(vaultB, 30e18);
        CcipObservation memory healthy = dispatcher.observation();
        assertEq(healthy.accountedBalance, 80e18, "healthy total");
        assertEq(healthy.unpricedCount, 0, "healthy: nothing unpriced");

        vaultA.setFaults(true, false, false);
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.accountedBalance, 30e18, "only B is counted");
        assertEq(obs.unpricedCount, 1, "one unpriced");
        assertEq(obs.unpricedCodes, 1, "vault index 0 failed on balanceOf");
        assertEq(dispatcher.accountedBalance(), 30e18, "accountedBalance view agrees");

        vaultA.setFaults(false, true, false);
        obs = dispatcher.observation();
        assertEq(obs.unpricedCodes, 2, "vault index 0 failed on convertToAssets");
        vaultA.setFaults(false, false, true);
        assertEq(dispatcher.observation().unpricedCount, 1, "short return flagged");
    }

    function testShouldStillSettleInboundTransferWhenVaultReverts() public {
        _position(vaultA, 50e18);
        _position(vaultB, 30e18);
        vaultA.setFaults(true, false, false);

        token.mint(address(executor), 100e18);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(vaultA), 1);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 1, "TRANSFER_SETTLED reached the executor");
        assertEq(dispatcher.trackedIdle(), 100e18, "idle credited");
    }

    function testShouldStillAnswerRecallWhenVaultReverts() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setFaults(false, true, false);

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(vaultA), 2);
        executor.requestAssetsFromDispatcher(REMOTE_CHAIN, 15e18, 15e18, 0, address(0), 2_000_000);

        assertEq(executor.lastRemoteStateVersion(REMOTE_CHAIN), 2, "RETURN_TRANSFER credited");
        assertEq(dispatcher.trackedIdle(), 85e18, "idle debited");
    }

    /// @dev IL-8784: the timelocked force-untrack is gone on CCIP. The tracked set equals the allowlist, so
    ///      removing the vault from the allowlist (a lane command) untracks it; there is nothing left to write off.
    function testShouldNotExposeForceUntrackOnCcip() public {
        (bool ok, ) = address(dispatcher).call(
            abi.encodeWithSignature("scheduleForceUntrack(address)", address(vaultA))
        );
        assertFalse(ok, "scheduleForceUntrack removed");
        (ok, ) = address(dispatcher).call(
            abi.encodeWithSignature("executeForceUntrack(uint256,address)", uint256(1), address(vaultA))
        );
        assertFalse(ok, "executeForceUntrack removed");
    }

    /// @dev A permanently unpriceable vault (every read reverts) leaves the tracked set as soon as it is removed from
    ///      the allowlist: the sweep reports it as unreadable (reason 1), the vault is untracked per D-028 and the
    ///      observation is healthy again, with no rescue timelock involved.
    function testShouldUntrackUnreadableVaultOnRemoval() public {
        _position(vaultA, 50e18);
        vaultA.setFaults(true, true, false);
        vaultA.setExtraFaults(true, false);
        assertEq(dispatcher.observation().unpricedCount, 1, "unpriced before removal");

        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultSweepResidual(address(vaultA), 0, 1, bytes4(0), true);
        _deallowlist(vaultA);

        assertFalse(dispatcher.isAllowedVault(address(vaultA)), "de-allowlisted although the vault is dead");
        assertFalse(dispatcher.isTrackedVault(address(vaultA)), "untracked: the sweep never blocks removal");
        assertEq(dispatcher.trackedVaultsLength(), 1, "set shrank");
        assertEq(dispatcher.trackedVaults(0), address(vaultB), "B remains");
        assertEq(dispatcher.observation().unpricedCount, 0, "observation healthy again");
    }

    /// @dev Adding still validates the vault shape: the dispatcher's `InvalidVault` NACKs the lane command, and the
    ///      vault is neither allowlisted nor tracked.
    function _assertAddRejected(address candidate_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = candidate_;
        executor.updateVaults(REMOTE_CHAIN, vaults, true, false, 0, address(0), 2_000_000);
        bytes32 id = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "add NACKed");
        assertFalse(dispatcher.isAllowedVault(candidate_), "not allowlisted");
        assertFalse(dispatcher.isTrackedVault(candidate_), "not tracked");
    }

    function testShouldStillRejectAddingVaultWhoseAssetReverts() public {
        MockFaultyVault dead = new MockFaultyVault(IERC20(address(token)), "D", "D");
        dead.setExtraFaults(true, false);
        _assertAddRejected(address(dead));
    }

    function testShouldRejectAddingCodelessAddress() public {
        _assertAddRejected(address(0xDEAD));
    }

    function testShouldRejectAddingVaultWithWrongAsset() public {
        MockFaultyVault wrong = new MockFaultyVault(IERC20(address(new ValueNeutralToken())), "W", "W");
        _assertAddRejected(address(wrong));
    }

    /// @dev A `convertToAssets` result above uint128 max is reported as unpriced (reason 2), never overflowing.
    function testShouldFlagConvertToAssetsAboveUint128AsUnpriced() public {
        _position(vaultA, 50e18);
        _position(vaultB, 30e18);
        vaultA.setConvertReturnsMax(true);
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.accountedBalance, 30e18, "only B is counted");
        assertEq(obs.unpricedCount, 1, "oversized value flagged");
        assertEq(obs.unpricedCodes, 2, "vault index 0 reported as convertToAssets failure");
    }

    /// @dev A gas-burning vault is capped at VAULT_READ_GAS per read and priced as unpriced; the others stay priced.
    function testShouldPriceOthersWhenOneVaultBurnsGas() public {
        _position(vaultA, 50e18);
        _position(vaultB, 30e18);
        vaultA.setExtraFaults(false, true);
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.accountedBalance, 30e18, "only B is counted");
        assertEq(obs.unpricedCount, 1, "burner flagged");
        assertEq(obs.unpricedCodes, 1, "burner failed on balanceOf");
    }

    /// @dev The router calls `ccipReceive` with a bounded gas budget (500k, below the 2M route `messageGasLimit`; BALANCE_REQUEST is not a command and needs no budget): the response
    ///      is still built and queued despite a burner. The mock router ignores route gas limits, so the gas is applied
    ///      by calling the dispatcher directly as the router.
    function testShouldStillAnswerBalanceRequestWithBoundedReceiveGasWhenVaultBurnsGas() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setExtraFaults(false, true);
        CcipClient.Any2EVMMessage memory message = CcipClient.Any2EVMMessage({
            messageId: keccak256("burner-balance-request"),
            sourceChainSelector: EXECUTOR_SELECTOR,
            sender: abi.encode(address(executor)),
            data: CcipMessages.encode(CcipMsgType.BALANCE_REQUEST, ""),
            destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
        });
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(vaultA), 1);
        vm.prank(address(router));
        dispatcher.ccipReceive{gas: 500_000}(message);
        assertTrue(dispatcher.processedCcipMessage(message.messageId), "message processed");
    }

    /// @dev The pre-check reverts when the caller cannot honour the per-read cap, so starving a read can never
    ///      masquerade as a vault failure.
    function testShouldRevertWhenCallerGasCannotCoverVaultRead() public {
        _position(vaultA, 50e18);
        vm.expectRevert(TrackedVaultPricingLib.InsufficientGasForVaultRead.selector);
        dispatcher.observation{gas: 150_000}();

        TrackedVaultPricingHarness harness = new TrackedVaultPricingHarness();
        vm.expectRevert(TrackedVaultPricingLib.InsufficientGasForVaultRead.selector);
        harness.read{gas: 150_000}(address(vaultA), address(dispatcher));
        (bool ok, uint256 amount) = harness.read{gas: 1_000_000}(address(vaultA), address(dispatcher));
        assertTrue(ok, "read succeeds with enough gas");
        assertEq(amount, 50e18, "balance read");
    }

    /// @dev BALANCE_REQUEST -> BALANCE_REPORT is built with a faulty vault: the event fires and the reported
    ///      balance is understated.
    function testShouldAnswerBalanceRequestWhenVaultReverts() public {
        _bridge(100e18);
        _position(vaultA, 50e18);
        vaultA.setFaults(true, false, false);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(vaultA), 1);
        executor.requestRemoteBalance(REMOTE_CHAIN, 0, address(0), 2_000_000);
        assertFalse(executor.balanceRequestOutstanding(REMOTE_CHAIN), "report delivered");
        assertEq(dispatcher.accountedBalance(), 100e18, "understated: vault A omitted");
    }

    // ------------------------------------------------------------------ IL-8645: asset() drift

    function _sendBusinessCommand(uint8 action_, bytes memory actionData_) private returns (bytes32 id) {
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: action_,
                minExecutionGas: 0,
                actionData: actionData_
            }),
            0,
            address(0),
            2_000_000
        );
        return executor.activeCommand(REMOTE_CHAIN);
    }

    /// @dev IL-8645: a deposit to an allowlisted vault whose asset() drifted is refused before any approval.
    function testShouldNackDepositWhenVaultAssetDrifted() public {
        _bridge(100e18);
        ValueNeutralToken other = new ValueNeutralToken();
        vaultA.setDriftedAsset(address(other));

        vm.recordLogs();
        bytes32 id = _sendBusinessCommand(
            uint8(BusinessAction.DEPOSIT),
            CrosschainMessages.encodeDepositAction(address(vaultA), 10e18, 0)
        );
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "deposit NACKed");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failedEmitted;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(dispatcher) && logs[i].topics[0] == CommandFailed.selector) {
                (bytes32 failedId, ) = abi.decode(logs[i].data, (bytes32, uint64));
                if (failedId == id) failedEmitted = true;
            }
        }
        assertTrue(failedEmitted, "CommandFailed emitted for the command id");
        assertEq(dispatcher.trackedIdle(), 100e18, "idle untouched");
        assertEq(token.allowance(address(dispatcher), address(vaultA)), 0, "nothing approved to the drifted vault");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "no shares");
    }

    /// @dev IL-8645: a held position in a drifted vault is reported as unpriced (reason 3); the others stay priced.
    function testShouldFlagDriftedAssetVaultAsUnpricedWithReasonThree() public {
        _position(vaultA, 50e18);
        _position(vaultB, 30e18);
        vaultA.setDriftedAsset(address(new ValueNeutralToken()));
        CcipObservation memory obs = dispatcher.observation();
        assertEq(obs.accountedBalance, 30e18, "only B is counted");
        assertEq(obs.unpricedCount, 1, "drifted vault unpriced");
        assertEq(obs.unpricedCodes, 3, "vault index 0: asset drift");

        // asset() reverting on a held position is the same condition.
        vaultA.setDriftedAsset(address(0));
        vaultA.setExtraFaults(true, false);
        obs = dispatcher.observation();
        assertEq(obs.unpricedCodes, 3, "reverting asset() is reason 3 too");
        assertEq(obs.accountedBalance, 30e18, "still only B");
    }

    function testShouldEmitUnpricedReasonThreeOnResponse() public {
        _position(vaultA, 50e18);
        vaultA.setDriftedAsset(address(new ValueNeutralToken()));
        token.mint(address(executor), 100e18);
        vm.expectEmit(false, false, false, true, address(dispatcher));
        emit TrackedVaultUnpriced(address(vaultA), 3);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
    }

    /// @dev IL-8645: exiting a drifted vault stays possible; redeem is deliberately not gated.
    function testShouldStillRedeemFromDriftedVault() public {
        _bridge(10e18);
        _position(vaultA, 50e18);
        vaultA.setDriftedAsset(address(new ValueNeutralToken()));
        assertTrue(dispatcher.isTrackedVault(address(vaultA)), "allowlisted vault is tracked");

        _sendBusinessCommand(
            uint8(BusinessAction.REDEEM),
            CrosschainMessages.encodeRedeemAction(address(vaultA), 50e18, 0)
        );
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "redeem ACKed, lane free");
        assertEq(vaultA.balanceOf(address(dispatcher)), 0, "position exited");
        assertEq(dispatcher.trackedIdle(), 60e18, "idle credited");
    }

    /// @dev A zero-share position carries no value: a drifted asset on an empty position is not flagged.
    function testShouldNotFlagEmptyPositionOfDriftedVault() public {
        _position(vaultB, 30e18);
        vaultA.setDriftedAsset(address(new ValueNeutralToken()));
        assertEq(dispatcher.observation().unpricedCount, 0, "empty drifted position is worth zero, not unpriced");
    }

    /// @dev De-allowlists through the sequenced UPDATE_VAULTS lane; a vault with shares (or an unreadable balance)
    ///      stays tracked.
    function _deallowlist(MockFaultyVault vault_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = address(vault_);
        executor.updateVaults(REMOTE_CHAIN, vaults, false, false, 0, address(0), 2_000_000);
    }
}
