// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {CcipCrosschainExecutor} from "../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";
import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction, CommandStatus} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command, CrosschainMessages} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipRouteConfig} from "../../contracts/crosschain/ccip/interfaces/ICcipCrosschain.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";
import {MockCcipRouteValidator} from "./mocks/MockCcipRouteValidator.sol";
import {MockRemotePlasmaVault, MockWithdrawManager} from "./mocks/MockRemoteVault.sol";

/// @title CcipDispatcherCommandErrorsTest
/// @notice IL-9047: the CCIP dispatcher's business commands revert with the same errors as the Stargate dispatcher.
///         A vault outside the tracked set is `VaultNotTracked`, a request above the held shares is
///         `RequestSharesUnavailable`, and a foreign receiver on REDEEM_FROM_REQUEST is `ReceiverMustBeSelf`.
///         The commands are run through the dispatcher's own `runStoredCommand` self-call entry, so each test
///         pins the exact selector and arguments of the revert (and the same command through the executor ends
///         NACKed).
contract CcipDispatcherCommandErrorsTest is CcipExecutorFixture {
    MockRemotePlasmaVault internal vault;
    MockWithdrawManager internal withdrawManager;

    function setUp() public {
        _fixtureSetUp();
        vault = new MockRemotePlasmaVault(IERC20(address(token)), "Remote", "rUSDC");
        withdrawManager = new MockWithdrawManager(address(vault));
        vault.setWithdrawManager(address(withdrawManager));
    }

    function _track(address vault_) private {
        address[] memory vaults = new address[](1);
        vaults[0] = vault_;
        Command memory command = _command(BusinessAction.DEPOSIT, "");
        vm.prank(address(dispatcher));
        dispatcher.runStoredCommand(CcipMsgType.UPDATE_VAULTS, command, abi.encode(vaults, true, false));
        assertTrue(dispatcher.isTrackedVault(vault_), "vault tracked");
    }

    function _command(BusinessAction action_, bytes memory actionData_) private view returns (Command memory) {
        return
            Command({
                commandId: bytes32((block.timestamp + 1 days) << 192),
                sequence: dispatcher.nextCommandSequence(),
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(action_),
                minExecutionGas: 0,
                actionData: actionData_
            });
    }

    /// @dev Runs the command as the dispatcher itself and expects the exact revert `expected_`.
    function _runExpectingRevert(BusinessAction action_, bytes memory actionData_, bytes memory expected_) private {
        Command memory command = _command(action_, actionData_);
        vm.expectRevert(expected_);
        vm.prank(address(dispatcher));
        dispatcher.runStoredCommand(CcipMsgType.COMMAND, command, "");
    }

    function testShouldRevertRedeemOnVaultOutsideTrackedSetWithVaultNotTracked() public {
        bytes memory data = CrosschainMessages.encodeRedeemAction(address(vault), 1e18, 0);
        _runExpectingRevert(
            BusinessAction.REDEEM,
            data,
            abi.encodeWithSelector(CcipCrosschainDispatcher.VaultNotTracked.selector, address(vault))
        );
    }

    function testShouldRevertRequestSharesOnVaultOutsideTrackedSetWithVaultNotTracked() public {
        bytes memory data = CrosschainMessages.encodeRequestSharesAction(
            address(withdrawManager),
            address(vault),
            1e18,
            type(uint256).max
        );
        _runExpectingRevert(
            BusinessAction.REQUEST_SHARES,
            data,
            abi.encodeWithSelector(CcipCrosschainDispatcher.VaultNotTracked.selector, address(vault))
        );
    }

    function testShouldRevertRedeemFromRequestOnVaultOutsideTrackedSetWithVaultNotTracked() public {
        bytes memory data = CrosschainMessages.encodeRedeemFromRequestAction(
            address(withdrawManager),
            address(vault),
            1e18,
            0,
            address(dispatcher)
        );
        _runExpectingRevert(
            BusinessAction.REDEEM_FROM_REQUEST,
            data,
            abi.encodeWithSelector(CcipCrosschainDispatcher.VaultNotTracked.selector, address(vault))
        );
    }

    function testShouldRevertRequestSharesAboveHeldSharesWithRequestSharesUnavailable() public {
        _track(address(vault));
        deal(address(vault), address(dispatcher), 3e18, true);
        bytes memory data = CrosschainMessages.encodeRequestSharesAction(
            address(withdrawManager),
            address(vault),
            5e18,
            type(uint256).max
        );
        _runExpectingRevert(
            BusinessAction.REQUEST_SHARES,
            data,
            abi.encodeWithSelector(CrosschainErrors.RequestSharesUnavailable.selector, 3e18, 5e18)
        );
    }

    function testShouldRevertRedeemFromRequestToForeignReceiverWithReceiverMustBeSelf() public {
        _track(address(vault));
        address receiver = address(0xBEEF);
        bytes memory data = CrosschainMessages.encodeRedeemFromRequestAction(
            address(withdrawManager),
            address(vault),
            1e18,
            0,
            receiver
        );
        _runExpectingRevert(
            BusinessAction.REDEEM_FROM_REQUEST,
            data,
            abi.encodeWithSelector(CrosschainErrors.ReceiverMustBeSelf.selector, receiver)
        );
    }

    /// @dev The fixture lane carries 500k gas, below the command budget (`CommandLaneGasTooLow`). Rewires the fixture's
    ///      `executor` / `dispatcher` pair over the same router, token and validator with a 2M-gas lane.
    function _deployHighGasLane() private {
        MockCcipRouteValidator routeValidator = MockCcipRouteValidator(factory);
        executor = new CcipCrosschainExecutor(
            address(router),
            factory,
            address(this),
            address(token),
            keccak256("USDC"),
            18,
            CcipCrosschainExecutor.SafetyConfig({
                rescueAdmin: RESCUE_ADMIN,
                rescueGuardian: address(0xB22),
                balanceProposer: address(this),
                balanceApprover: APPROVER,
                rescueDelay: RESCUE_DELAY,
                balanceStalenessMax: BALANCE_STALENESS_MAX,
                bigChangeBps: 2_000,
                minUpdateInterval: MIN_UPDATE_INTERVAL,
                transferStalenessMax: 1 days
            })
        );
        dispatcher = new CcipCrosschainDispatcher(
            address(router),
            factory,
            address(token),
            keccak256("USDC"),
            18,
            block.chainid,
            _route(EXECUTOR_SELECTOR, address(executor)),
            RESCUE_ADMIN,
            address(0xB22),
            RESCUE_DELAY
        );
        vm.prank(factory);
        dispatcher.configureVaults(new address[](0), true);
        CcipRouteConfig memory executorRoute = _route(DISPATCHER_SELECTOR, address(dispatcher));
        routeValidator.setRoute(REMOTE_CHAIN, executorRoute);
        routeValidator.registerExecutorRoute(address(executor), REMOTE_CHAIN, executorRoute);
        router.setSelector(address(executor), EXECUTOR_SELECTOR);
        router.setSelector(address(dispatcher), DISPATCHER_SELECTOR);
        vm.prank(factory);
        executor.markDispatcherReady(REMOTE_CHAIN);
    }

    function _route(uint64 selector_, address peer_) private pure returns (CcipRouteConfig memory) {
        return
            CcipRouteConfig({
                chainSelector: selector_,
                peer: peer_,
                feeToken: address(0),
                messageGasLimit: 2_000_000,
                tokenGasLimit: 2_000_000,
                maxFee: 0,
                enabled: true
            });
    }

    /// @dev The same untracked-vault REDEEM sent by the executor: the dispatcher NACKs and both sides end FAILED.
    function testShouldNackRedeemOnUntrackedVaultThroughExecutor() public {
        _deployHighGasLane();
        token.mint(address(executor), 100e18);
        executor.sendAssetToDispatcher(REMOTE_CHAIN, 100e18, 0, address(0), 2_000_000);
        _attest(dispatcher.accountedBalance());

        router.setAutoDeliver(false);
        executor.sendCommandToDispatcher(
            REMOTE_CHAIN,
            Command({
                commandId: bytes32(0),
                sequence: 0,
                commandConfigEpoch: 0,
                action: uint8(BusinessAction.REDEEM),
                minExecutionGas: 0,
                actionData: CrosschainMessages.encodeRedeemAction(address(vault), 1e18, 0)
            }),
            0,
            address(0),
            2_000_000
        );
        router.setAutoDeliver(true);
        bytes32 id = executor.activeCommand(REMOTE_CHAIN);
        assertTrue(id != bytes32(0), "command id read while active");
        router.deliverHeld(router.heldCount() - 1);

        assertEq(uint8(dispatcher.commandStatus(id)), uint8(CommandStatus.FAILED), "dispatcher FAILED");
        assertEq(uint8(executor.commandStatus(id)), uint8(CommandStatus.FAILED), "executor FAILED");
    }
}
