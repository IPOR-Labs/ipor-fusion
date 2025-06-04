// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title ReferralPlasmaVault
/// @notice Extension contract that adds referral functionality to ERC4626 vaults
/// @dev This contract acts as a wrapper around ERC4626 vaults, enabling referral tracking
/// while maintaining the standard vault deposit functionality. It uses SafeERC20 for
/// secure token transfers and approvals.
contract ReferralPlasmaVault {
    using SafeERC20 for IERC20;

    /// @notice Emitted when a deposit is made with a referral code
    /// @param referrer The address that initiated the deposit with referral
    /// @param referralCode The unique identifier for the referral
    event ReferralEvent(address indexed referrer, bytes32 referralCode);

    /// @notice Deposits assets into a vault and tracks the referral
    /// @dev This function:
    ///     1. Transfers assets from the caller to this contract
    ///     2. Approves the vault to spend the assets
    ///     3. Deposits the assets into the vault
    ///     4. Emits a referral event with the caller as referrer
    /// @param vault_ The address of the ERC4626 vault to deposit into
    /// @param assets_ The amount of assets to deposit
    /// @param receiver_ The address that will receive the vault shares
    /// @param referralCode_ The unique identifier for the referral
    /// @return The amount of vault shares minted to the receiver
    function deposit(
        address vault_,
        uint256 assets_,
        address receiver_,
        bytes32 referralCode_
    ) external returns (uint256) {
        address assetAddress = IERC4626(vault_).asset();
        IERC20(assetAddress).safeTransferFrom(msg.sender, address(this), assets_);
        IERC20(assetAddress).forceApprove(vault_, assets_);

        emit ReferralEvent(msg.sender, referralCode_);
        return IERC4626(vault_).deposit(assets_, receiver_);
    }
}
