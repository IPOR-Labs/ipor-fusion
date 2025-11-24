// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title ReferralPlasmaVault
/// @notice Extension contract that adds referral functionality to ERC4626 vaults
/// @dev This contract acts as a wrapper around ERC4626 vaults, enabling referral tracking
/// while maintaining the standard vault deposit functionality. It uses SafeERC20 for
/// secure token transfers and approvals.
contract ReferralPlasmaVault is Ownable {
    using SafeERC20 for IERC20;

    address public zapInAddress;

    error NotZapIn();
    error ZapInAddressIsZero();

    /// @notice Emitted when a deposit is made with a referral code
    /// @param referrer The address that initiated the deposit with referral
    /// @param referralCode The unique identifier for the referral
    event ReferralEvent(address indexed referrer, bytes32 referralCode);

    modifier onlyZapIn() {
        if (msg.sender != zapInAddress) {
            revert NotZapIn();
        }
        _;
    }

    constructor() Ownable(msg.sender) {}

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

    /// @notice Emits a referral event for zap-in operations
    /// @dev This function is called by the zap-in contract to emit referral events when users
    ///      perform zap-in operations with referral codes. It allows the referral system to track
    ///      successful zap-in transactions that include referral information.
    /// @param referrer The address of the user who initiated the zap-in operation with referral
    /// @param referralCode_ The unique referral code associated with the zap-in operation
    /// @custom:access Only the authorized zap-in contract can call this function
    /// @custom:security Protected by onlyZapIn modifier to prevent unauthorized referral event emission
    /// @custom:event Emits ReferralEvent with the referrer address and referral code for tracking
    function emitReferralForZapIn(address referrer, bytes32 referralCode_) external onlyZapIn {
        emit ReferralEvent(referrer, referralCode_);
    }

    /// @notice Sets the authorized zap-in contract address and renounces ownership
    /// @dev This function can only be called once by the owner. After setting the zap-in address,
    ///      the ownership is permanently renounced, making the contract immutable for future changes.
    ///      This ensures that only the designated zap-in contract can emit referral events.
    /// @param zapInAddress_ The address of the authorized zap-in contract that can emit referral events
    /// @custom:security This function permanently renounces ownership after execution, ensuring the zap-in address cannot be changed
    /// @custom:access Only the contract owner can call this function, and only once
    /// @custom:effect After execution, the contract becomes ownerless and the zap-in address is permanently set
    /// @custom:validation Reverts if the provided address is zero
    function setZapInAddress(address zapInAddress_) external onlyOwner {
        if (zapInAddress_ == address(0)) {
            revert ZapInAddressIsZero();
        }
        zapInAddress = zapInAddress_;
        renounceOwnership();
    }
}
