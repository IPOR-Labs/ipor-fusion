// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ICLGauge} from "../../fuses/aerodrome_slipstream/ext/ICLGauge.sol";
import {AreodromeSlipstreamSubstrateLib, AreodromeSlipstreamSubstrate, AreodromeSlipstreamSubstrateType} from "../../fuses/aerodrome_slipstream/AreodromeSlipstreamLib.sol";

/// @title AerodromeSlipstreamGaugeClaimFuse
/// @notice This contract handles the claiming of rewards from Aerodrome gauges.
/// @dev Claims AERO tokens from specified gauges and transfers them to the rewards claim manager.
contract AreodromeSlipstreamGaugeClaimFuse {
    using SafeERC20 for IERC20;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event AerodromeSlipstreamGaugeClaimFuseRewardsClaimed(
        address version,
        address gauge,
        address rewardToken,
        uint256 amount,
        address rewardsClaimManager
    );

    error AerodromeSlipstreamGaugeClaimFuseEmptyArray();
    error AerodromeSlipstreamGaugeClaimFuseUnsupportedGauge(address gauge);
    error AerodromeSlipstreamGaugeClaimFuseRewardsClaimManagerZeroAddress();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Claims rewards from specified Aerodrome gauges
    /// @param gauges_ Array of gauge addresses to claim rewards from
    function claim(address[] memory gauges_) external {
        uint256 len = gauges_.length;

        if (len == 0) {
            revert AerodromeSlipstreamGaugeClaimFuseEmptyArray();
        }

        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert AerodromeSlipstreamGaugeClaimFuseRewardsClaimManagerZeroAddress();
        }

        for (uint256 i; i < len; ++i) {
            _claim(gauges_[i], rewardsClaimManager);
        }
    }

    /// @dev Internal function to claim rewards for a specific gauge
    /// @param gauge_ The gauge address to claim rewards from
    /// @param rewardsClaimManager_ The rewards claim manager address
    function _claim(address gauge_, address rewardsClaimManager_) internal {
        // Check if the gauge is supported by the vault configuration
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AreodromeSlipstreamSubstrateLib.substrateToBytes32(
                    AreodromeSlipstreamSubstrate({
                        substrateAddress: gauge_,
                        substrateType: AreodromeSlipstreamSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert AerodromeSlipstreamGaugeClaimFuseUnsupportedGauge(gauge_);
        }

        address rewardToken = ICLGauge(gauge_).rewardToken();

        uint256 initialBalance = IERC20(rewardToken).balanceOf(address(this));

        uint256[] memory tokenIds = ICLGauge(gauge_).stakedValues(address(this));

        uint256 len = tokenIds.length;

        if (len == 0) {
            return;
        }

        uint256 earned = ICLGauge(gauge_).earned(address(this), tokenIds[0]);

        for (uint256 i; i < len; ++i) {
            ICLGauge(gauge_).getReward(tokenIds[i]);
        }

        uint256 finalBalance = IERC20(rewardToken).balanceOf(address(this));
        uint256 claimedAmount = finalBalance - initialBalance;

        if (claimedAmount > 0) {
            IERC20(rewardToken).safeTransfer(rewardsClaimManager_, claimedAmount);

            emit AerodromeSlipstreamGaugeClaimFuseRewardsClaimed(
                VERSION,
                gauge_,
                rewardToken,
                claimedAmount,
                rewardsClaimManager_
            );
        }
    }
}
