// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @title MockRWATarget
/// @notice Mock external protocol for RWA executor unit tests. Records call history.
contract MockRWATarget {
    /// @notice Per-call record.
    struct Call {
        bytes4 selector;
        bytes data;
    }

    Call[] public calls;

    /// @notice Reverts with a constant message when invoked via `revertingCall`.
    error TargetReverted();

    /// @notice Records the call and does nothing else.
    function noop() external {
        calls.push(Call({selector: this.noop.selector, data: msg.data}));
    }

    /// @notice Reverts with `TargetReverted`.
    function revertingCall() external {
        calls.push(Call({selector: this.revertingCall.selector, data: msg.data}));
        revert TargetReverted();
    }

    /// @notice Re-enter the caller via an arbitrary call.
    function reenter(address to_, bytes calldata data_) external {
        calls.push(Call({selector: this.reenter.selector, data: msg.data}));
        (bool ok, bytes memory ret) = to_.call(data_);
        if (!ok) {
            // bubble the inner revert
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function callsLength() external view returns (uint256) {
        return calls.length;
    }
}
