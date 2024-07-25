// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

contract GearboxV3FarmDTokenClaimFuse {
    event GearboxV3FarmDTokenClaimFuseRewardsClaimed(
        address version,
        address rewardsToken,
        uint256 rewardsTokenBalance,
        address rewardsClaimManager
    );

    error GearboxV3FarmDTokenClaimFuseRewardsClaimManagerZeroAddress(address version);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }
    function claim() external {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        if (len == 0) {
            return 0;
        }

        address farmDToken;
        address rewardsToken;
        uint256 rewardsTokenBalance;
        address rewardsClaimManager;

        for (uint256 i; i < len; ++i) {
            farmDToken = PlasmaVaultConfigLib.bytes32ToAddress(substrates[0]);
            if (farmDToken == address(0)) {
                continue;
            }
            rewardsToken = IFarmingPool(farmDToken).rewardsToken();
            rewardsTokenBalance = IFarmingPool(farmDToken).farmed(address(this));

            if (rewardsTokenBalance == 0) {
                revert;
            }

            IFarmingPool(farmDToken).claim();

            rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();

            if (rewardsClaimManager == address(0)) {
                revert GearboxV3FarmDTokenClaimFuseRewardsClaimManagerZeroAddress(VERSION);
            }

            IERC20(rewardsToken).transfer(rewardsClaimManager, rewardsTokenBalance);

            emit GearboxV3FarmDTokenClaimFuseRewardsClaimed(
                VERSION,
                rewardsToken,
                rewardsTokenBalance,
                rewardsClaimManager
            );
        }
    }
}
