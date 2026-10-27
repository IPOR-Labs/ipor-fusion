// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CrosschainTestBase} from "./CrosschainTestBase.sol";
import {CrosschainErrors} from "../../contracts/crosschain/lib/CrosschainErrors.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {StargateCrosschainExecutor} from "../../contracts/crosschain/stargate/StargateCrosschainExecutor.sol";

/// @title StargateExecutorManagerGuardTest
/// @notice IL-9166 (stargate-exec C-008): every one of the 11 `onlyManager` entries of the Stargate executor
///         reverts `UnauthorizedManager(stranger)` for a non-manager caller and leaves the sampled state untouched.
///         The dispatcher is brought up first, so each call would pass its own preconditions if the guard were absent.
contract StargateExecutorManagerGuardTest is CrosschainTestBase {
    address internal stranger = address(0xBAD0);

    function setUp() public {
        _baseSetUp();
        _readyDispatcher();
        _settle100();
        // Fresh tokens so `sendAssetToDispatcher` would otherwise pass its source-of-funds guard.
        usdc.mint(address(executor), 10e6);
    }

    function _sample() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    executor.idleLedger(),
                    executor.pendingTransferCount(REMOTE_CHAIN),
                    executor.returnInFlight(REMOTE_CHAIN),
                    executor.noClockReturnCount(REMOTE_CHAIN),
                    executor.activeCommandAction(REMOTE_CHAIN),
                    executor.nextSequenceToSend(REMOTE_CHAIN),
                    executor.settledRemoteBalance(REMOTE_CHAIN),
                    usdc.balanceOf(address(executor))
                )
            );
    }

    function _assertGuarded(bytes memory callData_, string memory name_) internal {
        bytes32 before = _sample();
        vm.prank(stranger);
        (bool ok, bytes memory ret) = address(executor).call(callData_);
        assertFalse(ok, name_);
        assertEq(
            keccak256(ret),
            keccak256(abi.encodeWithSelector(CrosschainErrors.UnauthorizedManager.selector, stranger)),
            name_
        );
        assertEq(_sample(), before, name_);
    }

    function testClaimAssetOnlyManager() public {
        _assertGuarded(abi.encodeCall(StargateCrosschainExecutor.claimAsset, (1e6)), "claimAsset");
    }

    function testRegisterChainOnlyManager() public {
        _assertGuarded(
            abi.encodeCall(
                StargateCrosschainExecutor.registerChain,
                (uint256(777), uint32(30777), _commandLaneOptions(30777))
            ),
            "registerChain"
        );
    }

    function testCreateDispatcherOnlyManager() public {
        address[] memory empty = new address[](0);
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.createDispatcher, (REMOTE_CHAIN, empty)),
            "createDispatcher"
        );
    }

    function testCancelDispatcherRequestOnlyManager() public {
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.cancelDispatcherRequest, (1)),
            "cancelDispatcherRequest"
        );
    }

    function testUpdatePlasmaVaultsOnlyManager() public {
        address[] memory empty = new address[](0);
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.updatePlasmaVaults, (REMOTE_CHAIN, empty)),
            "updatePlasmaVaults"
        );
    }

    function testSendAssetToDispatcherOnlyManager() public {
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.sendAssetToDispatcher, (REMOTE_CHAIN, 10e6, 0, bytes(""))),
            "sendAssetToDispatcher"
        );
    }

    function testRequestAssetsFromDispatcherOnlyManager() public {
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.requestAssetsFromDispatcher, (REMOTE_CHAIN, 10e6, 0, bytes(""))),
            "requestAssetsFromDispatcher"
        );
    }

    function testSendCommandToDispatcherOnlyManager() public {
        Command memory cmd = Command({
            commandId: bytes32(0),
            sequence: 0,
            commandConfigEpoch: 0,
            action: 0,
            minExecutionGas: 0,
            actionData: ""
        });
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.sendCommandToDispatcher, (REMOTE_CHAIN, cmd)),
            "sendCommandToDispatcher"
        );
    }

    function testRetryCommandOnlyManager() public {
        _assertGuarded(abi.encodeCall(StargateCrosschainExecutor.retryCommand, (REMOTE_CHAIN)), "retryCommand");
    }

    function testRetryCommandWithBudgetOnlyManager() public {
        _assertGuarded(
            abi.encodeCall(StargateCrosschainExecutor.retryCommandWithBudget, (REMOTE_CHAIN, uint64(1))),
            "retryCommandWithBudget"
        );
    }

    function testCancelCommandOnlyManager() public {
        _assertGuarded(abi.encodeCall(StargateCrosschainExecutor.cancelCommand, (REMOTE_CHAIN)), "cancelCommand");
    }
}
