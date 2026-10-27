// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipClient} from "../../contracts/crosschain/ccip/interfaces/CcipClient.sol";
import {CcipMessages, CcipMsgType} from "../../contracts/crosschain/ccip/lib/CcipMessages.sol";
import {CcipExecutorFixture} from "./CcipExecutorFixture.sol";

/// @notice External wrapper so `vm.expectRevert` can observe the internal library's reverts.
contract CcipMessagesHarness {
    function decode(bytes memory envelope_) external pure returns (CcipMsgType, bytes memory) {
        return CcipMessages.decode(envelope_);
    }
}

/// @title CcipMessagesTest
/// @notice IL-9021: `CcipMessages.decode` rejects a foreign envelope version and an out-of-range message type, at
///         codec level and through the executor's `ccipReceive` path.
contract CcipMessagesTest is CcipExecutorFixture {
    bytes32 internal constant MESSAGE_ID = keccak256("ccip-messages-test");

    CcipMessagesHarness internal harness;

    function setUp() public {
        _fixtureSetUp();
        harness = new CcipMessagesHarness();
    }

    function _raw(uint8 version_, uint8 rawType_) internal pure returns (bytes memory) {
        return abi.encode(version_, rawType_, bytes("payload"));
    }

    function testDecodeRejectsOlderVersion() public {
        uint8 wrong = CcipMessages.VERSION - 1;
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidVersion.selector, wrong));
        harness.decode(_raw(wrong, uint8(CcipMsgType.COMMAND)));
    }

    function testDecodeRejectsNewerVersion() public {
        uint8 wrong = CcipMessages.VERSION + 1;
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidVersion.selector, wrong));
        harness.decode(_raw(wrong, uint8(CcipMsgType.COMMAND)));
    }

    function testDecodeRejectsMessageTypeZero() public {
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidMessageType.selector, uint8(0)));
        harness.decode(_raw(CcipMessages.VERSION, 0));
    }

    function testDecodeRejectsMessageTypeAboveCancelCommand() public {
        uint8 wrong = uint8(CcipMsgType.CANCEL_COMMAND) + 1;
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidMessageType.selector, wrong));
        harness.decode(_raw(CcipMessages.VERSION, wrong));
    }

    function testDecodeAcceptsEveryDefinedType() public view {
        for (uint8 t = 1; t <= uint8(CcipMsgType.CANCEL_COMMAND); ++t) {
            (CcipMsgType decoded, bytes memory data) = harness.decode(_raw(CcipMessages.VERSION, t));
            assertEq(uint8(decoded), t, "type round-trips");
            assertEq(data, bytes("payload"), "payload round-trips");
        }
        assertEq(uint8(CcipMsgType.CANCEL_COMMAND), 17, "type range is 1..17");
    }

    function _message(bytes memory envelope_) internal view returns (CcipClient.Any2EVMMessage memory) {
        return
            CcipClient.Any2EVMMessage({
                messageId: MESSAGE_ID,
                sourceChainSelector: DISPATCHER_SELECTOR,
                sender: abi.encode(address(dispatcher)),
                data: envelope_,
                destTokenAmounts: new CcipClient.EVMTokenAmount[](0)
            });
    }

    function testExecutorRejectsWrongVersionFromRealPeerThenAcceptsCurrentVersion() public {
        uint8 wrong = CcipMessages.VERSION + 1;
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(CcipMessages.InvalidVersion.selector, wrong));
        executor.ccipReceive(_message(abi.encode(wrong, uint8(CcipMsgType.UPDATE_VAULTS_ACK), bytes(""))));
        assertFalse(executor.processedCcipMessage(MESSAGE_ID), "rejection must not consume the message id");

        // Positive twin: the same message id with the current version is accepted, so the revert above came from
        // the version check alone.
        vm.prank(address(router));
        executor.ccipReceive(_message(CcipMessages.encode(CcipMsgType.UPDATE_VAULTS_ACK, "")));
        assertTrue(executor.processedCcipMessage(MESSAGE_ID));
    }
}
