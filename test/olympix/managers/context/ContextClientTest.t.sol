// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {ContextClientHarness} from "test/test_helpers/ContextClientHarness.sol";
import {ContextClient} from "contracts/managers/context/ContextClient.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @dev Target contract: contracts/managers/context/ContextClient.sol
/// @dev Abstract — exercised via ContextClientHarness.
/// @dev Authority mock permits all restricted calls.

contract ContextClientTest is OlympixUnitTest("ContextClient") {
    ContextClientHarness internal target;
    address internal authority = address(0xA117);
    address internal sender = address(0x5E11);

    function setUp() public override {
        vm.etch(authority, hex"60006000");
        vm.mockCall(authority, abi.encodeWithSelector(IAccessManager.canCall.selector), abi.encode(true, uint32(0)));
        target = new ContextClientHarness();
        target.initialize(authority);
    }

    function test_example_setupContextStoresSender() public {
        target.setupContext(sender);
        assertEq(target.exposeGetSenderFromContext(), sender);
    }

    function test_example_clearContextRevertsWhenNoneSet() public {
        // With no context set, ContextClientStorageLib.getSenderFromContext() falls back to msg.sender,
        // so the `currentSender == address(0)` branch is only reachable when msg.sender == address(0).
        vm.prank(address(0));
        vm.expectRevert(ContextClient.ContextNotSet.selector);
        target.clearContext();
    }

    function test_setupContext_RevertWhenAlreadySet_opix_target_branch_48_True() public {
            // first call sets context successfully
            target.setupContext(sender);
    
            // second call should hit the `if (ContextClientStorageLib.isContextSenderSet())` true branch
            vm.expectRevert(ContextClient.ContextAlreadySet.selector);
            target.setupContext(sender);
        }
}