// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IGauge} from "../../fuses/aerodrome/ext/IGauge.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "../../fuses/aerodrome/AreodromeLib.sol";

/// @title AerodromeGaugeClaimFuse
/// @notice This contract handles the claiming of rewards from Aerodrome gauges.
/// @dev Claims AERO tokens from specified gauges and transfers them to the rewards claim manager.
contract AerodromeGaugeClaimFuse {
    using SafeERC20 for IERC20;

    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    event AerodromeGaugeClaimFuseRewardsClaimed(
        address version,
        address gauge,
        address rewardToken,
        uint256 amount,
        address rewardsClaimManager
    );

    error AerodromeGaugeClaimFuseEmptyArray();
    error AerodromeGaugeClaimFuseUnsupportedGauge(address gauge);
    error AerodromeGaugeClaimFuseRewardsClaimManagerZeroAddress();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Claims rewards from specified Aerodrome gauges
    /// @param gauges_ Array of gauge addresses to claim rewards from
    function claim(address[] memory gauges_) external {
        uint256 len = gauges_.length;

        if (len == 0) {
            revert AerodromeGaugeClaimFuseEmptyArray();
        }

        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert AerodromeGaugeClaimFuseRewardsClaimManagerZeroAddress();
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
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({substrateAddress: gauge_, substrateType: AerodromeSubstrateType.Gauge})
                )
            )
        ) {
            revert AerodromeGaugeClaimFuseUnsupportedGauge(gauge_);
        }

        address rewardToken = IGauge(gauge_).rewardToken();

        uint256 initialBalance = IERC20(rewardToken).balanceOf(address(this));

        IGauge(gauge_).getReward(address(this));

        uint256 finalBalance = IERC20(rewardToken).balanceOf(address(this));
        uint256 claimedAmount = finalBalance - initialBalance;

        if (claimedAmount > 0) {
            IERC20(rewardToken).safeTransfer(rewardsClaimManager_, claimedAmount);

            emit AerodromeGaugeClaimFuseRewardsClaimed(
                VERSION,
                gauge_,
                rewardToken,
                claimedAmount,
                rewardsClaimManager_
            );
        }
    }
}
