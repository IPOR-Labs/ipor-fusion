// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";

/// @notice Data structure for entering the UpdateWithdrawManagerMaintenanceFuse
struct UpdateWithdrawManagerMaintenanceFuseEnterData {
    /// @dev New withdraw manager address to be set
    address newManager;
}

/// @title Fuse for updating the withdraw manager address in the system
/// @dev This fuse allows authorized entities to update the withdraw manager using storage library
contract UpdateWithdrawManagerMaintenanceFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event WithdrawManagerUpdated(address version, address newManager);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(UpdateWithdrawManagerMaintenanceFuseEnterData memory data_) external {
        if (data_.newManager == address(0)) {
            return;
        }

        // Update the withdraw manager using storage library
        PlasmaVaultStorageLib.getWithdrawManager().manager = data_.newManager;

        emit WithdrawManagerUpdated(VERSION, data_.newManager);
    }

    function exit(bytes memory) external pure {
        // No exit functionality needed for this fuse
        return;
    }

    function getWithdrawManager() external view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManager().manager;
    }
}
