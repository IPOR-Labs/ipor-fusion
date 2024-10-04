// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ICometRewards} from "./ICometRewards.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/// @title CompoundV3ClaimFuse
/// @notice This contract handles the claiming of rewards from Compound V3, all comets.
/// @dev Uses PlasmaVaultLib for accessing the rewards claim manager address.
contract CompoundV3ClaimFuse {
    address public immutable VERSION;
    address public immutable COMET_REWARDS;

    event CompoundV3ClaimFuseRewardsClaimed(address version, address comet, address rewardsClaimManager);

    error ClaimManagerZeroAddress();
    error CometRewardsZeroAddress();

    constructor(address cometRewards_) {
        VERSION = address(this);

        if (cometRewards_ == address(0)) {
            revert CometRewardsZeroAddress();
        }

        COMET_REWARDS = cometRewards_;
    }

    /**
     * @notice Claims rewards for a specific Compound V3 market.
     * @param comet_ The address of the Compound V3 market to claim rewards for.
     */
    function claim(address comet_) external {
        address claimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (claimManager == address(0)) {
            revert ClaimManagerZeroAddress();
        }

        ICometRewards(COMET_REWARDS).claimTo(comet_, address(this), claimManager, true);

        emit CompoundV3ClaimFuseRewardsClaimed(VERSION, comet_, claimManager);
    }
}
