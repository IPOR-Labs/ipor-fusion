// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IREUL} from "./ext/IREUL.sol";

/**
 * @notice Data required to perform an rEUL claim.
 * @dev Each timestamp in `lockTimestamps_` must be a normalized lock timestamp as per IREUL's withdraw specification
 * (see IREUL.sol:10-13). The `allowRemainderLoss_` flag governs whether the call may transfer remaining rewards to the
 * receiver address if not all tokens can be claimed due to a rounding or lock schedule effect.
 * @param lockTimestamps An array of normalized lock timestamps to withdraw tokens for.
 * @param allowRemainderLoss If true, allows remainders as per lock schedule; see IREUL documentation.
 */

struct ClaimData {
    uint256[] lockTimestamps;
    bool allowRemainderLoss;
}

/// @title RewardEulerTokenClaimFuse
/// @notice Stub contract to enable reward claims from the Euler token rewards system.
/// @dev Implement claim() in derived contracts for specific reward-handling logic.
/// Security: Consider access control (e.g. onlyVault), reentrancy protection, and event emission.
contract RewardEulerTokenClaimFuse {
    error RewardEulerTokenClaimFuseInvalidAddress();
    error RewardEulerTokenClaimFuseRewardsClaimManagerNotSet();
    error RewardEulerTokenClaimFuseInvalidBalanceAfter();

    event RewardEulerTokenClaimFuseClaimed(address rewardsClaimManager, uint256 eulerRewardsManagerBalance);
    /// @notice Address of the rEUL token (reward token on Euler)
    address public immutable rEUL;
    /// @notice Address of the EUL token
    address public immutable EUL;

    /// @param rEUL_ Address of the rEUL token contract
    /// @param EUL_ Address of the EUL token contract
    constructor(address rEUL_, address EUL_) {
        if (rEUL_ == address(0)) {
            revert RewardEulerTokenClaimFuseInvalidAddress();
        }
        if (EUL_ == address(0)) {
            revert RewardEulerTokenClaimFuseInvalidAddress();
        }
        rEUL = rEUL_;
        EUL = EUL_;
    }
    /// @notice Claims accrued rewards from the Euler reward system.
    /// @dev This function should be overridden by child contracts to implement actual claim logic.
    function claim(ClaimData calldata data_) external {
        address rewardsClaimManager = PlasmaVaultLib.getRewardsClaimManagerAddress();
        if (rewardsClaimManager == address(0)) {
            revert RewardEulerTokenClaimFuseRewardsClaimManagerNotSet();
        }

        uint256 eulerRewardsManagerBalanceBefore = IERC20(EUL).balanceOf(rewardsClaimManager);

        IREUL(rEUL).withdrawToByLockTimestamps(rewardsClaimManager, data_.lockTimestamps, data_.allowRemainderLoss);

        uint256 eulerRewardsManagerBalanceAfter = IERC20(EUL).balanceOf(rewardsClaimManager);
        if (eulerRewardsManagerBalanceBefore > eulerRewardsManagerBalanceAfter) {
            revert RewardEulerTokenClaimFuseInvalidBalanceAfter();
        }

        emit RewardEulerTokenClaimFuseClaimed(
            rewardsClaimManager,
            eulerRewardsManagerBalanceAfter - eulerRewardsManagerBalanceBefore
        );
    }
}
