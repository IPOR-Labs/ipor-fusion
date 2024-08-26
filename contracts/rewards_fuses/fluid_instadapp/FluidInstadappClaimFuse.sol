// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFluidLendingStakingRewards} from "../../fuses/fluid_instadapp/ext/IFluidLendingStakingRewards.sol";

/// @title Claim Fuse for Fluid Instadapp rewards - responsible for claiming rewards from FluidLendingStakingRewards contracts
contract FluidInstadappClaimFuse {
    using SafeERC20 for IERC20;

    event FluidInstadappClaimFuseRewardsClaimed(
        address version,
        address rewardsToken,
        uint256 rewardsTokenBalance,
        address rewardsClaimManager
    );

    error FluidInstadappClaimFuseRewardsClaimManagerZeroAddress(address version);

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
            return;
        }

        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert FluidInstadappClaimFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        address fluidLendingStakingRewards;
        address rewardsToken;
        uint256 rewardsTokenBalance;

        for (uint256 i; i < len; ++i) {
            fluidLendingStakingRewards = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            if (fluidLendingStakingRewards == address(0)) {
                continue;
            }
            rewardsToken = IFluidLendingStakingRewards(fluidLendingStakingRewards).rewardsToken();
            rewardsTokenBalance = IFluidLendingStakingRewards(fluidLendingStakingRewards).earned(address(this));

            if (rewardsTokenBalance == 0) {
                continue;
            }

            IFluidLendingStakingRewards(fluidLendingStakingRewards).getReward();

            IERC20(rewardsToken).safeTransfer(rewardsClaimManager, rewardsTokenBalance);

            emit FluidInstadappClaimFuseRewardsClaimed(VERSION, rewardsToken, rewardsTokenBalance, rewardsClaimManager);
        }
    }
}
