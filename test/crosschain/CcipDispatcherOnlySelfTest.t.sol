// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipCrosschainDispatcher} from "../../contracts/crosschain/ccip/CcipCrosschainDispatcher.sol";
import {CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {BusinessAction} from "../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Command} from "../../contracts/crosschain/lib/CrosschainMessages.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @title CcipDispatcherOnlySelfTest
/// @notice IL-9042: `runStoredCommand` and `dispatchResponseSelf` are self-call only. Without the `OnlySelf` guard any
///         account could run `UPDATE_VAULTS` (allowlist the attacker's vault) or a business command directly.
contract CcipDispatcherOnlySelfTest is CcipExecutorFixture {
    address internal constant ATTACKER = address(0xBAD);
    address internal constant ATTACKER_VAULT = address(0xBAD1);

    function setUp() public {
        _fixtureSetUp();
    }

    function _command(BusinessAction action_) private view returns (Command memory) {
        return
            Command({
                commandId: bytes32((block.timestamp + 1 days) << 192),
                sequence: dispatcher.nextCommandSequence(),
                commandConfigEpoch: dispatcher.commandConfigEpoch(),
                action: uint8(action_),
                minExecutionGas: 0,
                actionData: ""
            });
    }

    /// @dev Negative: `OnlySelf` check removed from `runStoredCommand` -> the EOA's UPDATE_VAULTS runs -> fails.
    function testShouldRejectRunStoredCommandUpdateVaultsFromEoaWithOnlySelf() public {
        address[] memory vaults = new address[](1);
        vaults[0] = ATTACKER_VAULT;
        Command memory command = _command(BusinessAction.DEPOSIT);
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 headBefore = dispatcher.responseQueueHead();

        vm.expectRevert(CcipCrosschainDispatcher.OnlySelf.selector);
        vm.prank(ATTACKER);
        dispatcher.runStoredCommand(CcipMsgType.UPDATE_VAULTS, command, abi.encode(vaults, true, true));

        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "epoch unchanged");
        assertEq(dispatcher.trackedIdle(), idleBefore, "idle unchanged");
        assertFalse(dispatcher.isAllowedVault(ATTACKER_VAULT), "attacker vault not allowed");
        assertEq(dispatcher.responseQueueHead(), headBefore, "queue head unchanged");
    }

    /// @dev Negative: `OnlySelf` check removed from `runStoredCommand` -> the EOA's COMMAND is processed -> fails.
    function testShouldRejectRunStoredCommandBusinessCommandFromEoaWithOnlySelf() public {
        address[] memory vaults = new address[](1);
        vaults[0] = ATTACKER_VAULT;
        Command memory command = _command(BusinessAction.DEPOSIT);
        uint64 epochBefore = dispatcher.commandConfigEpoch();
        uint256 idleBefore = dispatcher.trackedIdle();
        uint64 headBefore = dispatcher.responseQueueHead();

        vm.expectRevert(CcipCrosschainDispatcher.OnlySelf.selector);
        vm.prank(ATTACKER);
        dispatcher.runStoredCommand(CcipMsgType.COMMAND, command, abi.encode(vaults, true, true));

        assertEq(dispatcher.commandConfigEpoch(), epochBefore, "epoch unchanged");
        assertEq(dispatcher.trackedIdle(), idleBefore, "idle unchanged");
        assertFalse(dispatcher.isAllowedVault(ATTACKER_VAULT), "attacker vault not allowed");
        assertEq(dispatcher.responseQueueHead(), headBefore, "queue head unchanged");
    }

    /// @dev Negative: `OnlySelf` check removed from `dispatchResponseSelf` -> the EOA reaches `_dispatchResponse` and
    ///      reverts with a different error -> fails.
    function testShouldRejectDispatchResponseSelfFromEoaWithOnlySelf() public {
        uint64 head = dispatcher.responseQueueHead();

        vm.expectRevert(CcipCrosschainDispatcher.OnlySelf.selector);
        vm.prank(ATTACKER);
        dispatcher.dispatchResponseSelf(head);

        assertEq(dispatcher.responseQueueHead(), head, "queue head unchanged");
    }
}
