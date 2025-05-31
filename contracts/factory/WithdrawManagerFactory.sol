// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {WithdrawManager} from "../managers/withdraw/WithdrawManager.sol";

/// @title WithdrawManagerFactory
/// @notice Factory contract for creating WithdrawManager instances
contract WithdrawManagerFactory {
    event WithdrawManagerCreated(address withdrawManager, address accessManager);

    /// @param accessManager_ The initial authority address for access control
    /// @return withdrawManager Address of the newly created WithdrawManager
    function getInstance(address accessManager_) external returns (address withdrawManager) {
        withdrawManager = address(new WithdrawManager(accessManager_));
        emit WithdrawManagerCreated(withdrawManager, accessManager_);
    }
}
