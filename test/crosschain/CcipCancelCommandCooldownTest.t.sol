// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipExecutorCommandLib} from "../../contracts/crosschain/ccip/lib/CcipExecutorCommandLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipCrosschainSupplyFuse} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {
    BusinessAction,
    CommandStatus,
    CrosschainConstants
} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @notice IL-8579: `CANCEL_COMMAND` repeats are allowed (a lost cancel must be re-sendable) but metered per
///         command by `CANCEL_COMMAND_COOLDOWN`, so a manager cannot drain the executor fee budget (CCIP).
/// @dev Driven through the vault -> CcipCrosschainCommandFuse -> executor path, with a real native fee.
contract CcipCancelCommandCooldownTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;
    uint256 internal constant FEE = 0.01 ether;
    address internal constant REMOTE_VAULT = address(0xBEEF); // granted on the vault, not tracked on the dispatcher

    MockERC20 internal token;
    MockCcipRouter internal router;
    CrosschainVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        address factory = address(routeValidator);
        vault = new CrosschainVaultHarness(address(token));
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(vault),
            address(token),
            keccak256("USDC"),
            6,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: address(0xA11),
                rescueGuardian: address(0xB22),
                balanceProposer: address(0xA33),
                balanceApprover: address(0xB44),
                rescueDelay: 3 days,
                balanceStalenessMax: 7 days,
                bigChangeBps: 2_000,
                minUpdateInterval: 1 hours,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            6,
            block.chainid,
            CcipRouteConfig({
                chainSelector: EXECUTOR_SELECTOR,
                peer: address(executor),
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 1 ether,
                enabled: true
            }),
            address(0xA11),
            address(0xB22),
            3 days
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = CcipRouteConfig({
            chainSelector: DISPATCHER_SELECTOR,
            peer: address(dispatcher),
            feeToken: address(0),
            messageGasLimit: 2_000_000,
            tokenGasLimit: 2_000_000,
            maxFee: 1 ether,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        router.setFee(FEE);

        CcipCrosschainSupplyFuse supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        CcipCrosschainCommandFuse commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, REMOTE_VAULT);
        vault.grantSubstrates(MARKET, substrates);

        vm.deal(address(dispatcher), 100 ether);
    }

    function _data(CcipCommandType t_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.maxFee = 1 ether;
        d.gasLimit = 2_000_000;
    }

    /// @dev ALPHA sends a command that the dispatcher NACKs (REDEEM from a vault it does not track).
    function _failedCommand() internal returns (bytes32 commandId) {
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.SEND_COMMAND);
        d.command = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: uint8(BusinessAction.REDEEM),
            minExecutionGas: 0,
            actionData: CrosschainMessages.encodeRedeemAction(REMOTE_VAULT, 1e6, 1e6)
        });
        vault.enterCcipCommand(d);
        commandId = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.FAILED), "NACK applied: FAILED");
    }

    function _cancel(bytes32 commandId_) internal {
        CcipCommandFuseEnterData memory d = _data(CcipCommandType.CANCEL_COMMAND);
        d.command.commandId = commandId_;
        vault.enterCcipCommand(d);
    }

    function testShouldRejectSecondCancelWithinCooldownAndChargeOneFee() public {
        vm.deal(address(executor), 51 * FEE);
        bytes32 commandId = _failedCommand();
        uint256 budget = address(executor).balance;

        router.setAutoDeliver(false); // no CCIP delivery in between
        uint256 heldBefore = router.heldCount();
        uint256 sentAt = block.timestamp;
        _cancel(commandId);

        for (uint256 i; i < 5; ++i) {
            vm.warp(sentAt + i * 1 minutes + 1 minutes);
            vm.expectRevert(
                abi.encodeWithSelector(
                    CcipExecutorCommandLib.CancelCooldown.selector,
                    REMOTE_CHAIN,
                    commandId,
                    sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
                )
            );
            _cancel(commandId);
        }
        // the boundary second is still inside the cooldown
        vm.warp(sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipExecutorCommandLib.CancelCooldown.selector,
                REMOTE_CHAIN,
                commandId,
                sentAt + CrosschainConstants.CANCEL_COMMAND_COOLDOWN
            )
        );
        _cancel(commandId);

        assertEq(router.heldCount() - heldBefore, 1, "one CANCEL_COMMAND left the executor");
        assertEq(budget - address(executor).balance, FEE, "exactly one fee charged");
    }

    function testShouldAcceptRepeatCancelAfterCooldownAndStillEndCancelled() public {
        vm.deal(address(executor), 51 * FEE);
        bytes32 commandId = _failedCommand();

        router.setAutoDeliver(false);
        uint256 heldBefore = router.heldCount();
        _cancel(commandId); // assume this one is lost in transit
        vm.warp(block.timestamp + CrosschainConstants.CANCEL_COMMAND_COOLDOWN);
        _cancel(commandId);
        assertEq(router.heldCount() - heldBefore, 2, "the re-sent cancel left the executor");

        // the dispatcher resolves the command once; the later duplicate is a no-op
        router.setAutoDeliver(true);
        router.deliverHeld(heldBefore + 1);
        assertEq(uint8(executor.commandStatus(commandId)), uint8(CommandStatus.CANCELLED), "cancelled by the ACK");
        assertEq(executor.activeCommand(REMOTE_CHAIN), bytes32(0), "slot freed");
    }

    function testShouldKeepRetryRejectedWhileCancelIsInFlight() public {
        vm.deal(address(executor), 51 * FEE);
        bytes32 commandId = _failedCommand();
        router.setAutoDeliver(false);
        _cancel(commandId);

        CcipCommandFuseEnterData memory d = _data(CcipCommandType.RETRY_COMMAND);
        d.command.commandId = commandId;
        vm.expectRevert(
            abi.encodeWithSelector(CcipExecutorCommandLib.CancelInFlight.selector, REMOTE_CHAIN, commandId)
        );
        vault.enterCcipCommand(d);
    }
}
