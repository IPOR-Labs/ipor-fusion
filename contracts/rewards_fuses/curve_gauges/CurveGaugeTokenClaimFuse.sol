// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IChildLiquidityGauge} from "../../fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

contract CurveGaugeTokenClaimFuse {
    using SafeERC20 for IERC20;

    event CurveGaugeTokenClaimFuseRewardsClaimed(
        address version,
        address gauge,
        address[] rewardsTokens,
        uint256[] rewardsTokenBalances,
        address rewardsClaimManager
    );

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
        address curveGauge;
        uint256 rewardCount;
        uint256 totalClaimable;
        address[] memory rewardsTokens;
        uint256[] memory rewardsTokenBalances;

        if (rewardsClaimManager == address(0)) {
            revert Errors.WrongAddress();
        }

        for (uint256 i; i < len; ++i) {
            curveGauge = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            rewardCount = IChildLiquidityGauge(curveGauge).reward_count();
            if (rewardCount == 0) {
                continue;
            }
            rewardsTokens = new address[](rewardCount);
            rewardsTokenBalances = new uint256[](rewardCount);
            for (uint256 j; j < rewardCount; ++j) {
                rewardsTokens[j] = IChildLiquidityGauge(curveGauge).reward_tokens(j);
                rewardsTokenBalances[j] = IChildLiquidityGauge(curveGauge).claimable_reward(
                    address(this),
                    rewardsTokens[j]
                );
                totalClaimable += rewardsTokenBalances[j];
            }

            if (totalClaimable > 0) {
                IChildLiquidityGauge(curveGauge).claim_rewards(address(this), address(this));
                totalClaimable = 0;
            }

            for (uint256 j; j < rewardCount; ++j) {
                if (rewardsTokenBalances[j] > 0) {
                    IERC20(rewardsTokens[j]).safeTransfer(rewardsClaimManager, rewardsTokenBalances[j]);
                }
            }

            emit CurveGaugeTokenClaimFuseRewardsClaimed(
                VERSION,
                curveGauge,
                rewardsTokens,
                rewardsTokenBalances,
                rewardsClaimManager
            );
        }
    }
}
