// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../../fuses/IFuse.sol";
import {MComptroller} from "../../fuses/moonwell/ext/MComptroller.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {MultiRewardDistributor} from "../../fuses/moonwell/ext/MultiRewardDistributor.sol";

/// @notice Data structure for claiming rewards from Moonwell markets
struct MoonwellClaimFuseData {
    /// @notice List of mToken addresses to claim rewards from
    address[] mTokens;
}

/// @dev Fuse for claiming rewards from Moonwell protocol
contract MoonwellClaimFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    MComptroller public immutable COMPTROLLER;

    event MoonwellClaimFuseRewardsClaimed(
        address version,
        address rewardToken,
        uint256 amount,
        address rewardsClaimManager
    );

    error MoonwellClaimFuseEmptyArray();
    error MoonwellClaimFuseRewardDistributorZeroAddress();
    error MoonwellClaimFuseRewardsClaimManagerZeroAddress();

    constructor(uint256 marketId_, address comptroller_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        COMPTROLLER = MComptroller(comptroller_);
    }

    /// @notice Claims rewards from specified mTokens
    /// @param data_ Struct containing array of mToken addresses to claim from
    function claim(MoonwellClaimFuseData calldata data_) external {
        uint256 len = data_.mTokens.length;

        if (len == 0) {
            revert MoonwellClaimFuseEmptyArray();
        }

        address rewardDistributor = COMPTROLLER.rewardDistributor();

        if (rewardDistributor == address(0)) {
            revert MoonwellClaimFuseRewardDistributorZeroAddress();
        }

        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();

        if (rewardsClaimManager == address(0)) {
            revert MoonwellClaimFuseRewardsClaimManagerZeroAddress();
        }

        for (uint256 i; i < len; ++i) {
            _claim(data_.mTokens[i], rewardDistributor, rewardsClaimManager);
        }
    }

    function _claim(address mToken_, address rewardDistributor_, address rewardsClaimManager_) internal {
        MultiRewardDistributor distributor = MultiRewardDistributor(rewardDistributor_);
        address plasmaVault = address(this);

        // Get reward token addresses
        MultiRewardDistributor.MarketConfig[] memory rewardConfig = distributor.getAllMarketConfigs(mToken_);

        uint256 len = rewardConfig.length;

        if (len == 0) {
            return;
        }

        uint256[] memory balanceBefore = new uint256[](len);
        address[] memory rewardTokens = new address[](len);

        for (uint256 i; i < len; ++i) {
            rewardTokens[i] = rewardConfig[i].emissionToken;
            balanceBefore[i] = IERC20(rewardTokens[i]).balanceOf(plasmaVault);
        }

        address[] memory mTokens = new address[](1);
        mTokens[0] = mToken_;
        COMPTROLLER.claimReward(plasmaVault, mTokens);

        for (uint256 i; i < rewardConfig.length; ++i) {
            uint256 balanceAfter = IERC20(rewardTokens[i]).balanceOf(plasmaVault);
            uint256 claimed = balanceAfter - balanceBefore[i];

            if (claimed > 0) {
                IERC20(rewardTokens[i]).safeTransfer(rewardsClaimManager_, claimed);
                emit MoonwellClaimFuseRewardsClaimed(VERSION, rewardTokens[i], claimed, rewardsClaimManager_);
            }
        }
    }
}
