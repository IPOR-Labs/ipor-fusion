// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {TacStakingDelegator} from "./TacStakingDelegator.sol";
import {TacStakingStorageLib} from "./lib/TacStakingStorageLib.sol";

/// @title TacStakingEmergencyFuse
/// @notice Fuse for emergency exit of TacStakingDelegator
/// @dev This fuse is used to emergency exit with all wTAC and native TAC from the TacStakingDelegator
contract TacStakingEmergencyFuse is IFuseCommon {
    error TacStakingEmergencyFuseInvalidDelegatorAddress();

    event TacStakingEmergencyFuseExit(address version);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Exit all wTAC and native TAC from the Delegator
    /// @dev Exit can be done only from TacStakingDelegator
    function exit() external {
        address payable delegator = payable(TacStakingStorageLib.getTacStakingDelegator());
        if (delegator == address(0)) {
            revert TacStakingEmergencyFuseInvalidDelegatorAddress();
        }
        TacStakingDelegator(delegator).emergencyExit();

        emit TacStakingEmergencyFuseExit(VERSION);
    }
}
