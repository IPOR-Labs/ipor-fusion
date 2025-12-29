// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {ISyrup} from "./ext/ISyrup.sol";

/**
 * @title SyrupClaimFuse
 * @notice A fuse contract responsible for claiming rewards from Syrup contract
 * @dev This contract acts as an intermediary to claim rewards and forward them to the RewardsClaimManager
 */
contract SyrupClaimFuse {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when rewards are successfully claimed from the Syrup contract
     * @param id Unique identifier of the token allocation that was claimed
     * @param asset Address of the reward token
     * @param amount Amount of rewards tokens claimed
     * @param rewardsClaimManager Address of the RewardsClaimManager receiving the claimed rewards
     */
    event SyrupClaimFuseRewardsClaimed(uint256 id, address asset, uint256 amount, address rewardsClaimManager);

    /**
     * @notice Thrown when the Syrup contract address is zero
     */
    error SyrupClaimFuseSyrupZeroAddress();

    /**
     * @notice Thrown when the RewardsClaimManager address is zero
     */
    error SyrupClaimFuseRewardsClaimManagerZeroAddress();
    /**
     * @notice Thrown when the claim amount is zero
     */
    error SyrupClaimFuseClaimAmountZero();

    /// @notice The address of this contract instance, used for version tracking
    address public immutable VERSION;

    address public immutable REWARD_DISTRIBUTOR;

    /**
     * @notice Constructs a new SyrupClaimFuse instance
     * @param rewardDistributor_ The address of the Reward Distributor contract
     */
    constructor(address rewardDistributor_) {
        if (rewardDistributor_ == address(0)) {
            revert SyrupClaimFuseSyrupZeroAddress();
        }

        VERSION = address(this);
        REWARD_DISTRIBUTOR = rewardDistributor_;
    }

    /**
     * @notice Claims rewards from Syrup contract and forwards them to the RewardsClaimManager
     * @dev Claims rewards to address(this) (PlasmaVault) first, then transfers to RewardsClaimManager
     *      The account parameter is always set to address(this) (PlasmaVault) when calling the Syrup contract
     * @param id_ Unique identifier of the token allocation
     * @param claimAmount_ Amount of tokens to claim
     * @param proof_ Proof that the recipient is part of the Merkle tree of token allocations
     */
    function claim(uint256 id_, uint256 claimAmount_, bytes32[] calldata proof_) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert SyrupClaimFuseRewardsClaimManagerZeroAddress();
        }
        if (claimAmount_ == 0) {
            revert SyrupClaimFuseClaimAmountZero();
        }

        address plasmaVault = address(this);
        address asset = ISyrup(REWARD_DISTRIBUTOR).asset();

        uint256 balanceBefore = IERC20(asset).balanceOf(plasmaVault);

        ISyrup(REWARD_DISTRIBUTOR).claim(id_, plasmaVault, claimAmount_, proof_);

        uint256 claimedAmount = IERC20(asset).balanceOf(plasmaVault) - balanceBefore;

        if (claimedAmount > 0) {
            IERC20(asset).safeTransfer(rewardsClaimManager, claimedAmount);

            emit SyrupClaimFuseRewardsClaimed(id_, asset, claimedAmount, rewardsClaimManager);
        }
    }
}
