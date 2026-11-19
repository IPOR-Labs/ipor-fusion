// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {CcipDispatcherLib} from "../../../contracts/crosschain/ccip/lib/CcipDispatcherLib.sol";

/// @title CcipQueuedResponseHarness
/// @notice IL-9621: holds its own response queue (`CcipDispatcherLib.QueuedResponse`, the layout the dispatcher
///         declares) and runs the linked queue helpers `raiseQueuedBalances` and `unwindQueuedReturn` on it, so a test
///         can write arbitrary entries and read every field back.
contract CcipQueuedResponseHarness {
    mapping(uint64 => CcipDispatcherLib.QueuedResponse) internal _queue;

    /// @notice Writes the queue entry `responseId_` field by field.
    /// @param responseId_ The response id.
    /// @param data_ The stored envelope.
    /// @param amountLD_ The token amount, local decimals.
    /// @param returnDeadline_ The recall deadline (0 for none).
    function setEntry(uint64 responseId_, bytes memory data_, uint256 amountLD_, uint256 returnDeadline_) external {
        _queue[responseId_] = CcipDispatcherLib.QueuedResponse({
            data: data_,
            amountLD: amountLD_,
            returnDeadline: returnDeadline_
        });
    }

    /// @notice Every field of the queue entry `responseId_` (all zero for an id that was never written).
    /// @param responseId_ The response id.
    /// @return data The stored envelope.
    /// @return amountLD The token amount, local decimals.
    /// @return returnDeadline The recall deadline (0 for none).
    function entry(
        uint64 responseId_
    ) external view returns (bytes memory data, uint256 amountLD, uint256 returnDeadline) {
        CcipDispatcherLib.QueuedResponse storage stored = _queue[responseId_];
        return (stored.data, stored.amountLD, stored.returnDeadline);
    }

    /// @notice Runs `CcipDispatcherLib.raiseQueuedBalances` on this harness's queue.
    /// @param firstId_ The first response id to raise.
    /// @param lastId_ The last response id to raise (inclusive).
    /// @param amountSD_ The amount added to each carried balance, shared decimals.
    function raiseQueuedBalances(uint64 firstId_, uint64 lastId_, uint256 amountSD_) external {
        CcipDispatcherLib.raiseQueuedBalances(_queue, firstId_, lastId_, amountSD_);
    }

    /// @notice Runs `CcipDispatcherLib.unwindQueuedReturn` on this harness's queue.
    /// @param headId_ The response id of the return to release.
    /// @param lastId_ The last response id to raise (inclusive).
    /// @return operationId The operation id of the released return.
    /// @return amountSD The released amount, shared decimals.
    function unwindQueuedReturn(
        uint64 headId_,
        uint64 lastId_
    ) external returns (bytes32 operationId, uint256 amountSD) {
        return CcipDispatcherLib.unwindQueuedReturn(_queue, headId_, lastId_);
    }
}
