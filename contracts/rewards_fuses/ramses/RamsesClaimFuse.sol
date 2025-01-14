// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {INonfungiblePositionManagerRamses} from "../../fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";

/**
 * @title RamsesClaimFuse
 * @dev Contract for claiming rewards for NFT positions in the Ramses system.
 */
contract RamsesClaimFuse {
    using SafeERC20 for IERC20;

    error RamsesClaimFuseRewardsClaimManagerNotSet();

    address public immutable VERSION;
    /// @notice Address of the non-fungible position manager
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Error thrown when the lengths of tokenIds and tokenRewards arrays do not match
    error RamsesClaimFuseTokenIdsAndTokenRewardsLengthMismatch();

    /// @notice Event emitted after a reward is transferred
    /// @param tokenId The ID of the token
    /// @param token The address of the token
    /// @param reward The amount of the reward
    event RamsesClaimFuseTransferredReward(uint256 tokenId, address token, uint256 reward);

    /**
     * @dev Constructor for the contract
     * @param nonfungiblePositionManager_ The address of the non-fungible position manager
     */
    constructor(address nonfungiblePositionManager_) {
        VERSION = address(this);
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Function to claim rewards for multiple positions
     * @param tokenIds Array of token IDs
     * @param tokenRewards Array of arrays of reward token addresses
     */
    function claim(uint256[] memory tokenIds, address[][] memory tokenRewards) external {
        uint256 tokenIdsLen = tokenIds.length;
        uint256 tokenRewardsLen = tokenRewards.length;

        if (tokenIdsLen == 0 || tokenRewardsLen == 0) {
            return;
        }

        if (tokenIdsLen != tokenRewardsLen) {
            revert RamsesClaimFuseTokenIdsAndTokenRewardsLengthMismatch();
        }

        for (uint256 i; i < tokenIdsLen; ++i) {
            _claim(tokenIds[i], tokenRewards[i]);
        }
    }

    function _claim(uint256 tokenId, address[] memory tokenRewards) internal {
        address plasmaVault = address(this);
        uint256 len = tokenRewards.length;

        uint256[] memory balancesBefore = new uint256[](len);

        for (uint256 i; i < len; ++i) {
            balancesBefore[i] = IERC20(tokenRewards[i]).balanceOf(plasmaVault);
        }

        INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).getReward(tokenId, tokenRewards);

        uint256 balanceAfter;
        uint256 rewardToTransfer;
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();

        if (rewardsClaimManager == address(0)) {
            revert RamsesClaimFuseRewardsClaimManagerNotSet();
        }

        for (uint256 i; i < len; ++i) {
            balanceAfter = IERC20(tokenRewards[i]).balanceOf(plasmaVault);
            rewardToTransfer = balanceAfter - balancesBefore[i];

            if (rewardToTransfer > 0) {
                IERC20(tokenRewards[i]).safeTransfer(rewardsClaimManager, rewardToTransfer);
                emit RamsesClaimFuseTransferredReward(tokenId, tokenRewards[i], rewardToTransfer);
            }
        }
    }
}
