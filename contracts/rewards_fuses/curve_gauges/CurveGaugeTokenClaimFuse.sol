// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IChildLiquidityGauge} from "../../fuses/curve_gauge/ext/IChildLiquidityGauge.sol";

contract CurveGaugeTokenClaimFuse {
    using SafeERC20 for IERC20;

    event CurveGaugeTokenClaimFuseRewardsClaimed(
        address version,
        address gauge,
        address rewardsToken,
        uint256 rewardsTokenBalance,
        address rewardsClaimManager
    );

    error CurveGaugeTokenClaimFuseRewardsClaimManagerZeroAddress(address version);
    error CurveGaugeInvalidGauge(address gauge);

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

        address curveGauge;
        uint256 rewardCount;
        uint256 rewardsToken;
        uint256 rewardsTokenBalance;
        address rewardsClaimManager;

        for (uint256 i; i < len; ++i) {
            curveGauge = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            rewardCount = IChildLiquidityGauge(curveGauge).reward_count();
            for (uint256 j; j < rewardCount; ++j) {
                rewardsToken = IChildLiquidityGauge(curveGauge).reward_tokens(j);
                rewardsTokenBalance = IChildLiquidityGauge(curveGauge).claimable_reward(address(this), rewardsToken);
                IChildLiquidityGauge(curveGauge).claim_rewards(address(this), address(this));
                rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
                if (rewardsClaimManager == address(0)) {
                    revert CurveGaugeTokenClaimFuseRewardsClaimManagerZeroAddress(VERSION);
                }
                IERC20(rewardsToken).safeTransfer(rewardsClaimManager, rewardsTokenBalance);
            }
            emit CurveGaugeTokenClaimFuseRewardsClaimed(
                VERSION,
                curveGauge,
                rewardsToken,
                rewardsTokenBalance,
                rewardsClaimManager
            );
        }
    }
}
