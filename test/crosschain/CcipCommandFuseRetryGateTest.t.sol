// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipSendLib} from "../../contracts/crosschain/ccip/lib/CcipSendLib.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {
    CcipCrosschainSupplyFuse,
    CcipSupplyFuseEnterData,
    CcipSupplyFuseExitData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainSupplyFuse.sol";
import {
    CcipCrosschainCommandFuse,
    CcipCommandType,
    CcipCommandFuseEnterData
} from "../../contracts/fuses/crosschain/ccip/CcipCrosschainCommandFuse.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CommandStatus, BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainSubstrateLib} from "../../contracts/fuses/crosschain/lib/CrosschainSubstrateLib.sol";
import {CrosschainVaultHarness} from "./mocks/CrosschainVaultHarness.sol";
import {MockCcipRouter} from "./mocks/MockCcipRouter.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";

/// @notice IL-8600: `RETRY_COMMAND` reads the stored command action and gates a DEPOSIT like `SEND_COMMAND`.
contract CcipCommandFuseRetryGateTest is Test {
    uint256 internal constant MARKET = IporFusionMarkets.CROSSCHAIN;
    uint256 internal constant REMOTE_CHAIN = 8453;
    uint64 internal constant EXECUTOR_SELECTOR = 1;
    uint64 internal constant DISPATCHER_SELECTOR = 2;

    MockERC20 internal token;
    MockCcipRouter internal router;
    CrosschainVaultHarness internal vault;
    CcipCrosschainExecutor internal executor;
    CcipCrosschainDispatcher internal dispatcher;
    CcipCrosschainSupplyFuse internal supplyFuse;
    CcipCrosschainCommandFuse internal commandFuse;
    address internal factory;

    function setUp() public {
        token = new MockERC20("USD Coin", "USDC", 6);
        router = new MockCcipRouter();
        MockCcipRouteValidator routeValidator = new MockCcipRouteValidator();
        factory = address(routeValidator);
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
                bigChangeBps: 2_000, // == ATTESTATION_ANCHOR_BAND_BPS, the constructor ceiling (IL-8058)
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
                maxFee: 0,
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
            maxFee: 0,
            enabled: true
        });
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);

        supplyFuse = new CcipCrosschainSupplyFuse(MARKET);
        commandFuse = new CcipCrosschainCommandFuse(MARKET);
        vault.setCcipFuses(address(supplyFuse), address(commandFuse));
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        vault.grantSubstrates(MARKET, substrates);
    }

    uint256 internal constant EXECUTOR_CHAIN_BLOCKED_SLOT = 30; // CcipCrosschainExecutor.chainBlocked

    function _data(CcipCommandType t_) internal view returns (CcipCommandFuseEnterData memory d) {
        d.commandType = t_;
        d.executor = address(executor);
        d.chainId = REMOTE_CHAIN;
        d.gasLimit = 2_000_000;
    }

    function _block() internal {
        vm.store(
            address(executor),
            keccak256(abi.encode(REMOTE_CHAIN, EXECUTOR_CHAIN_BLOCKED_SLOT)),
            bytes32(uint256(1))
        );
        assertTrue(executor.chainBlocked(REMOTE_CHAIN), "slot constant stale");
    }

    function _grantRemoteVault(address remoteVault_) internal {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = CrosschainSubstrateLib.executorSubstrate(address(executor));
        substrates[1] = CrosschainSubstrateLib.remoteVaultSubstrate(REMOTE_CHAIN, remoteVault_);
        vault.grantSubstrates(MARKET, substrates);
    }

    function _sendCommand(uint8 action_, bytes memory actionData_)
        internal
        view
        returns (CcipCommandFuseEnterData memory d)
    {
        d = _data(CcipCommandType.SEND_COMMAND);
        d.command = Command({
            commandId: bytes32(0), sequence: 0, commandConfigEpoch: 0, action: action_, minExecutionGas: 0, actionData: actionData_
        });
    }

    error NavFailClosed();

    /// @dev Sends `action_` for an unallowlisted remote vault: the dispatcher NACKs it (FAILED stored command).
    function _failedCommand(uint8 action_, bytes memory actionData_, address remoteVault_)
        internal
        returns (bytes32 id)
    {
        _grantRemoteVault(remoteVault_);
        vault.enterCcipCommand(_sendCommand(action_, actionData_));
        id = executor.activeCommand(REMOTE_CHAIN);
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "precondition: FAILED");
    }

    function _retry(bytes32 id_) internal view returns (CcipCommandFuseEnterData memory d) {
        d = _data(CcipCommandType.RETRY_COMMAND);
        d.command.commandId = id_;
    }

    function _failedDeposit() internal returns (bytes32) {
        address remoteVault = address(0xBEEF);
        return _failedCommand(
            uint8(BusinessAction.DEPOSIT), CrosschainMessages.encodeDepositAction(remoteVault, 1e6, 1e6), remoteVault
        );
    }

    function testShouldGateRetryOfDepositLikeSendCommand() public {
        bytes32 id = _failedDeposit();
        assertEq(executor.commandAction(id), uint8(BusinessAction.DEPOSIT));

        // NAV fail-closed: the live getBalance() read reverts the retry.
        vm.mockCallRevert(
            address(executor),
            abi.encodeWithSelector(executor.getBalance.selector),
            abi.encodeWithSelector(NavFailClosed.selector)
        );
        vm.expectRevert(NavFailClosed.selector);
        vault.enterCcipCommand(_retry(id));
        vm.clearMockedCalls();

        // NAV healthy: the retry proceeds (new-exposure path performs one live NAV read) and re-arms PENDING/FAILED.
        vm.expectCall(address(executor), abi.encodeWithSelector(executor.getBalance.selector), 1);
        vault.enterCcipCommand(_retry(id));
    }

    function testShouldTreatRetryOfRedeemAsRecovery() public {
        address remoteVault = address(0xBEEF);
        bytes32 id = _failedCommand(
            uint8(BusinessAction.REDEEM), CrosschainMessages.encodeRedeemAction(remoteVault, 1e6, 1e6), remoteVault
        );
        assertEq(executor.commandAction(id), uint8(BusinessAction.REDEEM));

        // Fail-closed NAV and a blocked chain must not stop a recovery, and no NAV read is made.
        _block();
        vm.mockCallRevert(
            address(executor),
            abi.encodeWithSelector(executor.getBalance.selector),
            abi.encodeWithSelector(NavFailClosed.selector)
        );
        vm.expectCall(address(executor), abi.encodeWithSelector(executor.getBalance.selector), 0);
        vault.enterCcipCommand(_retry(id));
    }

    function testShouldRefuseRetryOfDepositOnBlockedChain() public {
        bytes32 id = _failedDeposit();
        _block();
        vm.expectRevert(
            abi.encodeWithSelector(
                CcipCrosschainCommandFuse.CommandFuseChainBlocked.selector, address(executor), REMOTE_CHAIN
            )
        );
        vault.enterCcipCommand(_retry(id));
    }
}
