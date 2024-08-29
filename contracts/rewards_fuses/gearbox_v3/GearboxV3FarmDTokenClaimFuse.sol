// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFarmingPool} from "../../fuses/gearbox_v3/ext/IFarmingPool.sol";

/// @title Claim Fuse for GearboxV3 FarmDToken rewards - responsible for claiming rewards from FarmDToken contracts
contract GearboxV3FarmDTokenClaimFuse {
    using SafeERC20 for IERC20;

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

    /// @notice Claims rewards from FarmDToken contracts
    function claim() external {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = substrates.length;

        if (len == 0) {
            return;
        }

        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert GearboxV3FarmDTokenClaimFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        address farmDToken;
        address rewardsToken;
        uint256 rewardsTokenBalance;

        for (uint256 i; i < len; ++i) {
            farmDToken = PlasmaVaultConfigLib.bytes32ToAddress(substrates[i]);
            if (farmDToken == address(0)) {
                continue;
            }
            rewardsToken = IFarmingPool(farmDToken).rewardsToken();
            rewardsTokenBalance = IFarmingPool(farmDToken).farmed(address(this));

            if (rewardsTokenBalance == 0) {
                continue;
            }

            IFarmingPool(farmDToken).claim();

            IERC20(rewardsToken).safeTransfer(rewardsClaimManager, rewardsTokenBalance);

            emit GearboxV3FarmDTokenClaimFuseRewardsClaimed(
                VERSION,
                rewardsToken,
                rewardsTokenBalance,
                rewardsClaimManager
            );
        }
    }
}
