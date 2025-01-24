// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

import {IFluidMerkleDistributor} from "./ext/IFluidMerkleDistributor.sol";
/**
 * @title FluidProofClaimFuse
 * @notice A fuse contract responsible for claiming rewards from Fluid's MerkleDistributor
 * @dev This contract acts as an intermediary to claim rewards and forward them to the RewardsClaimManager
 */
contract FluidProofClaimFuse {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when rewards are successfully claimed from the FluidMerkleDistributor
     * @param version Address of this contract instance
     * @param rewardsToken Address of the token being claimed as rewards
     * @param rewardsTokenAmount Amount of rewards tokens claimed
     * @param rewardsClaimManager Address of the RewardsClaimManager receiving the claimed rewards
     * @param cycle The cycle number for which rewards were claimed
     */
    event FluidProofClaimFuseRewardsClaimed(
        address version,
        address rewardsToken,
        uint256 rewardsTokenAmount,
        address rewardsClaimManager,
        uint256 cycle
    );

    /**
     * @notice Thrown when the RewardsClaimManager address is zero
     * @param version Address of this contract instance
     */
    error FluidProofClaimFuseRewardsClaimManagerZeroAddress(address version);

    /**
     * @notice Thrown when the FluidMerkleDistributor address is zero
     * @param version Address of this contract instance
     */
    error FluidProofClaimFuseDistributorZeroAddress(address version);

    /**
     * @notice Thrown when attempting to claim from an unsupported distributor
     * @param distributor Address of the unsupported distributor
     */
    error FluidProofClaimFuseUnsupportedDistributor(address distributor);

    /**
     * @notice Thrown when the rewards token address is zero
     * @param version Address of this contract instance
     */
    error FluidProofClaimFuseRewardsTokenZeroAddress(address version);

    /// @notice The address of this contract instance, used for version tracking
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /**
     * @notice Constructs a new FluidProofClaimFuse instance
     * @param marketId_ The market ID this fuse is associated with
     */
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Claims rewards from FluidMerkleDistributor and forwards them to the RewardsClaimManager
     * @dev Verifies the distributor is supported and uses merkle proofs for claim validation
     * @param distributor_ The address of FluidMerkleDistributor contract
     * @param cumulativeAmount_ The total amount of rewards claimable
     * @param positionType_ The type of position for which rewards are being claimed
     * @param positionId_ The unique identifier of the position
     * @param cycle_ The cycle number for which rewards are being claimed
     * @param merkleProof_ The merkle proof that validates this claim
     * @param metadata_ Additional metadata required for the claim
     */
    function claim(
        address distributor_,
        uint256 cumulativeAmount_,
        uint8 positionType_,
        bytes32 positionId_,
        uint256 cycle_,
        bytes32[] calldata merkleProof_,
        bytes memory metadata_
    ) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert FluidProofClaimFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        if (distributor_ == address(0)) {
            revert FluidProofClaimFuseDistributorZeroAddress(VERSION);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, distributor_)) {
            revert FluidProofClaimFuseUnsupportedDistributor(distributor_);
        }

        IERC20 rewardsToken = IERC20(IFluidMerkleDistributor(distributor_).TOKEN());

        if (address(rewardsToken) == address(0)) {
            revert FluidProofClaimFuseRewardsTokenZeroAddress(VERSION);
        }

        uint256 balanceBefore = rewardsToken.balanceOf(address(this));

        IFluidMerkleDistributor(distributor_).claim(
            address(this),
            cumulativeAmount_,
            positionType_,
            positionId_,
            cycle_,
            merkleProof_,
            metadata_
        );

        uint256 rewardsAmount = rewardsToken.balanceOf(address(this)) - balanceBefore;

        if (rewardsAmount > 0) {
            rewardsToken.safeTransfer(rewardsClaimManager, rewardsAmount);

            emit FluidProofClaimFuseRewardsClaimed(
                VERSION,
                address(rewardsToken),
                rewardsAmount,
                rewardsClaimManager,
                cycle_
            );
        }
    }
}
