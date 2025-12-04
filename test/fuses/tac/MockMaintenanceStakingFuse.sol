// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TacStakingDelegator} from "../../../contracts/fuses/tac/TacStakingDelegator.sol";
import {TacStakingStorageLib} from "../../../contracts/fuses/tac/lib/TacStakingStorageLib.sol";

contract MockMaintenanceStakingFuse {
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        MARKET_ID = marketId_;
    }

    error TacStakingFuseInvalidDelegatorAddress();

    function executeBatch(
        address[] calldata targets,
        bytes[] calldata calldatas
    ) external returns (bytes[] memory results) {
        address payable delegator = payable(TacStakingStorageLib.getTacStakingDelegator());
        if (delegator == address(0)) {
            revert TacStakingFuseInvalidDelegatorAddress();
        }
        return TacStakingDelegator(delegator).executeBatch(targets, calldatas);
    }
}
