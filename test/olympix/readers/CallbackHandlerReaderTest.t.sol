// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {CallbackHandlerReader} from "contracts/readers/CallbackHandlerReader.sol";

/// @dev Target contract: contracts/readers/CallbackHandlerReader.sol
contract CallbackHandlerReaderTest is OlympixUnitTest("CallbackHandlerReader") {
    CallbackHandlerReader internal reader;

    function setUp() public override {
        reader = new CallbackHandlerReader();
    }

    function test_example_getCallbackHandlerReturnsZeroWhenUnset() public {
        // direct call reads the reader's own (empty) storage context
        address handler = reader.getCallbackHandler(makeAddr("sender"), bytes4(0x12345678));

        assertEq(handler, address(0), "unset callback handler should resolve to zero address");
    }

    function test_example_getCallbackHandlersLengthMismatchReverts() public {
        address[] memory senders = new address[](2);
        senders[0] = makeAddr("senderA");
        senders[1] = makeAddr("senderB");
        bytes4[] memory sigs = new bytes4[](1);
        sigs[0] = bytes4(0x12345678);

        vm.expectRevert(CallbackHandlerReader.CallbackHandlerReaderInvalidArrayLength.selector);
        reader.getCallbackHandlers(senders, sigs);
    }

    function test_example_getCallbackHandlersEmptyArraysReturnEmpty() public view {
        address[] memory senders = new address[](0);
        bytes4[] memory sigs = new bytes4[](0);

        address[] memory handlers = reader.getCallbackHandlers(senders, sigs);

        assertEq(handlers.length, 0, "empty query should return an empty result");
    }
}
