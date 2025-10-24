// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IDistributor} from "./ext/IDistributor.sol";

/**
 * @title MerklClaimFuse
 * @notice A fuse contract responsible for claiming rewards from Merkl's Distributor
 * @dev This contract acts as an intermediary to claim rewards and forward them to the RewardsClaimManager
 */
contract MerklClaimFuse {
    using SafeERC20 for IERC20;

    /**
     * @notice Emitted when rewards are successfully claimed from the Merkl Distributor
     * @param version Address of this contract instance
     * @param rewardsToken Address of the token being claimed as rewards
     * @param rewardsTokenAmount Amount of rewards tokens claimed
     * @param rewardsClaimManager Address of the RewardsClaimManager receiving the claimed rewards
     */
    event MerklClaimFuseRewardsClaimed(
        address version,
        address rewardsToken,
        uint256 rewardsTokenAmount,
        address rewardsClaimManager
    );

    /**
     * @notice Thrown when the RewardsClaimManager address is zero
     * @param version Address of this contract instance
     */
    error MerklClaimFuseRewardsClaimManagerZeroAddress(address version);

    /**
     * @notice Thrown when the Distributor address is zero
     * @param version Address of this contract instance
     */
    error MerklClaimFuseDistributorZeroAddress(address version);

    /// @notice The address of this contract instance, used for version tracking
    address public immutable VERSION;

    /// @notice The address of the Merkl Distributor contract
    address public immutable DISTRIBUTOR;

    /**
     * @notice Constructs a new MerklClaimFuse instance
     * @param distributor_ The address of the Merkl Distributor contract
     */
    constructor(address distributor_) {
        if (distributor_ == address(0)) {
            revert MerklClaimFuseDistributorZeroAddress(address(this));
        }

        VERSION = address(this);
        DISTRIBUTOR = distributor_;
    }

    /**
     * @notice Claims rewards from Merkl Distributor and forwards them to the RewardsClaimManager
     * @dev Uses claimWithRecipient to claim rewards directly to the RewardsClaimManager
     * @param tokens_ Array of reward token addresses to claim
     * @param amounts_ Array of claimable amounts for each token
     * @param proofs_ Array of merkle proofs for each token
     * @param doNotTransferToRewardManager_ Array of token addresses to skip transferring to rewards manager
     */
    function claim(
        address[] calldata tokens_,
        uint256[] calldata amounts_,
        bytes32[][] calldata proofs_,
        address[] calldata doNotTransferToRewardManager_
    ) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert MerklClaimFuseRewardsClaimManagerZeroAddress(VERSION);
        }

        _claimRewards(tokens_, amounts_, proofs_, doNotTransferToRewardManager_, rewardsClaimManager);
    }

    /**
     * @notice Internal function to handle the actual claiming logic
     * @param tokens_ Array of reward token addresses to claim
     * @param amounts_ Array of claimable amounts for each token
     * @param proofs_ Array of merkle proofs for each token
     * @param doNotTransferToRewardManager_ Array of token addresses to skip transferring to rewards manager
     * @param rewardsClaimManager_ Address of the rewards claim manager
     */
    function _claimRewards(
        address[] calldata tokens_,
        uint256[] calldata amounts_,
        bytes32[][] calldata proofs_,
        address[] calldata doNotTransferToRewardManager_,
        address rewardsClaimManager_
    ) internal {
        uint256 tokensLength = tokens_.length;

        // Build users array - always use address(this) as the PlasmaVault address
        address[] memory users = new address[](tokensLength);
        for (uint256 i; i < tokensLength; ++i) {
            users[i] = address(this);
        }

        // Record balances before claiming to calculate claimed amounts
        uint256[] memory balancesBefore = new uint256[](tokensLength);
        for (uint256 i; i < tokensLength; ++i) {
            balancesBefore[i] = IERC20(tokens_[i]).balanceOf(address(this));
        }

        // Call the Merkl Distributor to claim rewards
        IDistributor(DISTRIBUTOR).claim(users, tokens_, amounts_, proofs_);

        // Process each claimed token
        for (uint256 i; i < tokensLength; ++i) {
            _processClaimedToken(tokens_[i], balancesBefore[i], doNotTransferToRewardManager_, rewardsClaimManager_);
        }
    }

    /**
     * @notice Internal function to process a single claimed token
     * @param token_ The token address to process
     * @param balanceBefore_ The token balance before claiming
     * @param doNotTransferToRewardManager_ Array of token addresses to skip transferring to rewards manager
     * @param rewardsClaimManager_ Address of the rewards claim manager
     */
    function _processClaimedToken(
        address token_,
        uint256 balanceBefore_,
        address[] calldata doNotTransferToRewardManager_,
        address rewardsClaimManager_
    ) internal {
        uint256 claimedAmount = IERC20(token_).balanceOf(address(this)) - balanceBefore_;

        if (claimedAmount > 0) {
            // Only transfer to rewards manager if not in the skip list
            if (!_shouldSkipTransfer(token_, doNotTransferToRewardManager_)) {
                IERC20(token_).safeTransfer(rewardsClaimManager_, claimedAmount);
            }

            emit MerklClaimFuseRewardsClaimed(VERSION, token_, claimedAmount, rewardsClaimManager_);
        }
    }

    /**
     * @notice Internal function to check if a token should be skipped from transfer to rewards manager
     * @param token_ The token address to check
     * @param doNotTransferToRewardManager_ Array of token addresses to skip transferring
     * @return shouldSkip True if the token should be skipped, false otherwise
     */
    function _shouldSkipTransfer(
        address token_,
        address[] calldata doNotTransferToRewardManager_
    ) internal pure returns (bool shouldSkip) {
        for (uint256 j; j < doNotTransferToRewardManager_.length; ++j) {
            if (token_ == doNotTransferToRewardManager_[j]) {
                return true;
            }
        }
        return false;
    }
}
