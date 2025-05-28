// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";

/// @title WithdrawManagerFactory
/// @notice Factory contract for creating WithdrawManager instances
contract WithdrawManagerFactory {
    /// @notice Emitted when a new WithdrawManager is created
    event WithdrawManagerCreated(address indexed manager);

    /// @notice Creates a new WithdrawManager
    /// @param accessManager_ The initial authority address for access control
    /// @return Address of the newly created WithdrawManager
    function createWithdrawManager(address accessManager_) external returns (address) {
        WithdrawManager manager = new WithdrawManager(accessManager_);

        emit WithdrawManagerCreated(address(manager));
        return address(manager);
    }
}
