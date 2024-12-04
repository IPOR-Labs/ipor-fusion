// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IUniversalRewardsDistributor} from "./ext/IUniversalRewardsDistributor.sol";

/**
 * @title MorphoClaimFuse
 * @notice A fuse contract responsible for claiming rewards from Morpho's UniversalRewardsDistributor
 * @dev This contract acts as an intermediary to claim rewards and forward them to the RewardsClaimManager
 */
contract MorphoClaimFuse {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when rewards are successfully claimed from the UniversalRewardsDistributor
     * @param version Address of this contract instance
     * @param rewardsToken Address of the token being claimed as rewards
     * @param rewardsTokenAmount Amount of rewards tokens claimed
     * @param rewardsClaimManager Address of the RewardsClaimManager receiving the claimed rewards
     */
    event MorphoClaimFuseRewardsClaimed(
        address version,
        address rewardsToken,
        uint256 rewardsTokenAmount,
        address rewardsClaimManager
    );

    /**
     * @notice Thrown when the RewardsClaimManager address is zero
     * @param version Address of this contract instance
     */
    error MorphoClaimFuseRewardsClaimManagerZeroAddress(address version);

    /**
     * @notice Thrown when the UniversalRewardsDistributor address is zero
     * @param version Address of this contract instance
     */
    error MorphoClaimFuseUniversalRewardsDistributorZeroAddress(address version);

    /**
     * @notice Thrown when attempting to claim from an unsupported distributor
     * @param distributor Address of the unsupported distributor
     */
    error MorphoClaimFuseUnsupportedDistributor(address distributor);

    /// @notice The address of this contract instance, used for version tracking
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /**
     * @notice Constructs a new MorphoClaimFuse instance
     * @param marketId_ The market ID this fuse is associated with
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Claims rewards from UniversalRewardsDistributor and forwards them to the RewardsClaimManager
     * @dev Verifies the distributor is supported and uses merkle proofs for claim validation
     * @param universalRewardsDistributor The address of UniversalRewardsDistributor contract
     * @param rewardsToken The address of the reward token to claim
     * @param claimable The overall claimable amount of token rewards
     * @param proof The merkle proof that validates this claim
     */
    function claim(
        address universalRewardsDistributor,
        address rewardsToken,
        uint256 claimable,
        bytes32[] calldata proof
    ) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert MorphoClaimFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        if (universalRewardsDistributor == address(0)) {
            revert MorphoClaimFuseUniversalRewardsDistributorZeroAddress(VERSION);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, universalRewardsDistributor)) {
            revert MorphoClaimFuseUnsupportedDistributor(universalRewardsDistributor);
        }

        uint256 rewardsAmount = IUniversalRewardsDistributor(universalRewardsDistributor).claim(
            address(this),
            rewardsToken,
            claimable,
            proof
        );

        if (rewardsAmount > 0) {
            IERC20(rewardsToken).safeTransfer(rewardsClaimManager, rewardsAmount);

            emit MorphoClaimFuseRewardsClaimed(VERSION, rewardsToken, rewardsAmount, rewardsClaimManager);
        }
    }
}
