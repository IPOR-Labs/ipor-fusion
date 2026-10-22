// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title RecoveryBatcher
/// @notice Stands in for a Safe MultiSend: runs a list of calls in one transaction and reverts all of them if
///         any one fails. The recovery runbook needs this to act on a vault paused by GUARDIAN, because a
///         closed target rejects every restricted call until it is reopened.
contract RecoveryBatcher {
    struct Call {
        address target;
        bytes data;
    }

    address public immutable OWNER;

    error NotOwner(address caller);

    constructor(address owner_) {
        OWNER = owner_;
    }

    function run(Call[] calldata calls_) external {
        if (msg.sender != OWNER) revert NotOwner(msg.sender);
        uint256 len = calls_.length;
        for (uint256 i; i < len; ++i) {
            Address.functionCall(calls_[i].target, calls_[i].data);
        }
    }
}
