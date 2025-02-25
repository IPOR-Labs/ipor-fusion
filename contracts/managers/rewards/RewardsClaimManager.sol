// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FusesLib} from "../../libraries/FusesLib.sol";
import {FuseAction} from "../../vaults/PlasmaVault.sol";
import {RewardsClaimManagersStorageLib, VestingData} from "./RewardsClaimManagersStorageLib.sol";
import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {IRewardsClaimManager} from "../../interfaces/IRewardsClaimManager.sol";
import {ContextClient} from "../context/ContextClient.sol";

/// @title RewardsClaimManager
/// @notice Manages the claiming and vesting of rewards from the Plasma Vault
/// @dev This contract implements role-based access control for various reward management functions
///
/// Access Control:
/// - TRANSFER_REWARDS_ROLE: Required for transfer function
/// - CLAIM_REWARDS_ROLE: Required for claimRewards function
/// - FUSE_MANAGER_ROLE: Required for addRewardFuses and removeRewardFuses functions
/// - ATOMIST_ROLE: Required for setupVestingTime function
/// - Other functions are publicly accessible: balanceOf, isRewardFuseSupported, getVestingData, getRewardsFuses,
///   updateBalance, transferVestedTokensToVault
contract RewardsClaimManager is AccessManagedUpgradeable, ContextClient, IRewardsClaimManager {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    /// @notice The underlying token used for rewards
    address public immutable UNDERLYING_TOKEN;

    /// @notice The address of the Plasma Vault contract
    address public immutable PLASMA_VAULT;

    error UnableToTransferUnderlyingToken();

    /// @notice Emitted when rewards are withdrawn
    /// @param amount The amount of tokens withdrawn
    event AmountWithdrawn(uint256 amount);

    /// @notice Initializes the RewardsClaimManager
    /// @param initialAuthority_ The initial authority address for access control
    /// @param plasmaVault_ The address of the Plasma Vault contract
    /// @dev Sets up initial vesting time and configures access control
    /// @custom:access Only during initialization
    constructor(address initialAuthority_, address plasmaVault_) initializer {
        super.__AccessManaged_init_unchained(initialAuthority_);

        UNDERLYING_TOKEN = PlasmaVault(plasmaVault_).asset();
        PLASMA_VAULT = plasmaVault_;

        RewardsClaimManagersStorageLib.setupVestingTime(1);
    }

    /// @notice Returns the current balance of vested tokens
    /// @return The amount of tokens currently available for claiming
    /// @dev Calculates vested amount based on vesting schedule
    /// @custom:access Public
    function balanceOf() public view returns (uint256) {
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        if (data.vestingTime == 0) {
            return IERC20(UNDERLYING_TOKEN).balanceOf(address(this));
        }

        if (data.updateBalanceTimestamp == 0) {
            return 0;
        }

        uint256 ratio = 1e18;
        if (block.timestamp >= data.updateBalanceTimestamp) {
            ratio = ((block.timestamp - data.updateBalanceTimestamp) * 1e18) / data.vestingTime;
        }

        if (ratio == 0) {
            return 0;
        }

        if (ratio >= 1e18) {
            return data.lastUpdateBalance - data.transferredTokens;
        } else {
            return Math.mulDiv(data.lastUpdateBalance, ratio, 1e18) - data.transferredTokens;
        }
    }

    /// @notice Checks if a given fuse is supported for rewards
    /// @param fuse_ The address of the fuse to check
    /// @return bool True if the fuse is supported
    /// @custom:access Public
    function isRewardFuseSupported(address fuse_) external view returns (bool) {
        return FusesLib.isFuseSupported(fuse_);
    }

    /// @notice Gets the current vesting data
    /// @return VestingData struct containing vesting schedule information
    /// @custom:access Public
    function getVestingData() external view returns (VestingData memory) {
        return RewardsClaimManagersStorageLib.getVestingData();
    }

    /// @notice Returns array of supported reward fuses
    /// @return Array of fuse addresses
    /// @custom:access Public
    function getRewardsFuses() external view returns (address[] memory) {
        return FusesLib.getFusesArray();
    }

    /// @notice Transfers tokens to a specified address
    /// @param asset_ The token to transfer
    /// @param to_ The recipient address
    /// @param amount_ The amount to transfer
    /// @dev Cannot transfer the underlying token
    /// @custom:access TRANSFER_REWARDS_ROLE
    function transfer(address asset_, address to_, uint256 amount_) external restricted {
        if (asset_ == UNDERLYING_TOKEN) {
            revert UnableToTransferUnderlyingToken();
        }

        if (amount_ == 0) {
            return;
        }

        IERC20(asset_).safeTransfer(to_, amount_);
    }

    /// @notice Claims rewards from supported fuses
    /// @param calls_ Array of FuseAction structs defining claim operations
    /// @custom:access CLAIM_REWARDS_ROLE
    function claimRewards(FuseAction[] calldata calls_) external restricted {
        uint256 len = calls_.length;

        for (uint256 i; i < len; ++i) {
            if (!FusesLib.isFuseSupported(calls_[i].fuse)) {
                revert FusesLib.FuseUnsupported(calls_[i].fuse);
            }
        }

        PlasmaVault(PLASMA_VAULT).claimRewards(calls_);
    }

    /// @notice Updates the balance and vesting schedule
    /// @dev Transfers available tokens to Plasma Vault and updates vesting data
    /// @custom:access UPDATE_REWARDS_BALANCE_ROLE
    function updateBalance() external restricted {
        uint256 balance = balanceOf();

        if (balance > 0) {
            IERC20(UNDERLYING_TOKEN).safeTransfer(PLASMA_VAULT, balance);
        }

        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        data.updateBalanceTimestamp = block.timestamp.toUint32();
        data.lastUpdateBalance = IERC20(UNDERLYING_TOKEN).balanceOf(address(this)).toUint128();
        data.transferredTokens = 0;

        RewardsClaimManagersStorageLib.setVestingData(data);
    }

    /// @notice Transfers vested tokens to the Plasma Vault
    /// @dev Moves available vested tokens and updates accounting
    /// @custom:access PUBLIC_ROLE
    function transferVestedTokensToVault() external restricted {
        uint256 balance = balanceOf();

        if (balance == 0) {
            return;
        }

        IERC20(UNDERLYING_TOKEN).safeTransfer(PLASMA_VAULT, balance);
        RewardsClaimManagersStorageLib.updateTransferredTokens(balance);

        emit AmountWithdrawn(balance);
    }

    /// @notice Adds new reward fuses
    /// @param fuses_ Array of fuse addresses to add
    /// @custom:access FUSE_MANAGER_ROLE
    function addRewardFuses(address[] calldata fuses_) external restricted {
        uint256 len = fuses_.length;

        for (uint256 i; i < len; ++i) {
            FusesLib.addFuse(fuses_[i]);
        }
    }

    /// @notice Removes reward fuses
    /// @param fuses_ Array of fuse addresses to remove
    /// @custom:access FUSE_MANAGER_ROLE
    function removeRewardFuses(address[] calldata fuses_) external restricted {
        uint256 len = fuses_.length;

        for (uint256 i; i < len; ++i) {
            FusesLib.removeFuse(fuses_[i]);
        }
    }

    /// @notice Sets the vesting duration
    /// @param vestingTime_ The new vesting duration in seconds
    /// @custom:access ATOMIST_ROLE
    function setupVestingTime(uint256 vestingTime_) external restricted {
        RewardsClaimManagersStorageLib.setupVestingTime(vestingTime_);
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}
