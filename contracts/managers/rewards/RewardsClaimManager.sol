// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessManagedUpgradeable} from "../access/AccessManagedUpgradeable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
    /// @dev Retrieved from storage library
    function UNDERLYING_TOKEN() public view returns (address) {
        return RewardsClaimManagersStorageLib.getUnderlyingToken();
    }

    /// @notice The address of the Plasma Vault contract
    /// @dev Retrieved from storage library
    function PLASMA_VAULT() public view returns (address) {
        return RewardsClaimManagersStorageLib.getPlasmaVault();
    }

    error UnableToTransferUnderlyingToken();

    /// @notice Thrown when setupVestingTime would force balanceOf() into the
    /// transient clamp window where the linearly-vested portion is below
    /// transferredTokens. Surfaced instead of silently corrupting state.
    /// @param requestedVestingTime The vestingTime requested by the caller.
    /// @param maxSafeVestingTime The largest vestingTime that still keeps
    /// vested_now >= transferredTokens at the current block.
    error UnsafeVestingTime(uint256 requestedVestingTime, uint256 maxSafeVestingTime);

    /// @notice Thrown when rescheduleVesting parameters would still leave the
    /// contract in a state where balanceOf() must clamp.
    /// @param newVestingTime The proposed new vesting duration.
    /// @param newUpdateBalanceTimestamp The proposed new anchor timestamp.
    /// @param vestedAfter Linearly-vested portion at block.timestamp under the proposed schedule.
    /// @param transferredTokens Currently-tracked transferredTokens.
    error UnsafeReschedule(
        uint256 newVestingTime,
        uint256 newUpdateBalanceTimestamp,
        uint256 vestedAfter,
        uint256 transferredTokens
    );

    /// @notice Thrown when newVestingTime is zero.
    error InvalidVestingTime();

    /// @notice Thrown when newUpdateBalanceTimestamp is in the future relative to block.timestamp.
    error InvalidTimestamp();

    /// @notice Emitted when rewards are withdrawn
    /// @param amount The amount of tokens withdrawn
    event AmountWithdrawn(uint256 amount);

    /// @notice Emitted when the vesting schedule is rebased in place without
    /// transferring tokens to the Plasma Vault (rescheduleVesting path).
    /// @param newVestingTime New vesting duration in seconds.
    /// @param newUpdateBalanceTimestamp New anchor timestamp for the linear curve.
    /// @param transferredTokens Unchanged transferredTokens at the time of reschedule.
    /// @param lastUpdateBalance Unchanged lastUpdateBalance at the time of reschedule.
    event VestingRescheduled(
        uint256 newVestingTime,
        uint256 newUpdateBalanceTimestamp,
        uint256 transferredTokens,
        uint256 lastUpdateBalance
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address initialAuthority_, address plasmaVault_) initializer {
        _initialize(initialAuthority_, plasmaVault_);
    }

    /// @notice Initializes the RewardsClaimManager with access manager and plasma vault (for cloning)
    /// @param initialAuthority_ The address of the access control manager
    /// @param plasmaVault_ The address of the Plasma Vault contract
    /// @dev This method is called after cloning to initialize the contract
    function proxyInitialize(address initialAuthority_, address plasmaVault_) external initializer {
        _initialize(initialAuthority_, plasmaVault_);
    }

    function _initialize(address initialAuthority_, address plasmaVault_) private {
        super.__AccessManaged_init_unchained(initialAuthority_);

        RewardsClaimManagersStorageLib.setUnderlyingToken(PlasmaVault(plasmaVault_).asset());
        RewardsClaimManagersStorageLib.setPlasmaVault(plasmaVault_);
    }

    /// @notice Returns the current balance of vested tokens
    /// @return The amount of tokens currently available for claiming
    /// @dev Calculates vested amount based on vesting schedule. Uses saturating subtraction:
    /// transferredTokens may temporarily exceed the linearly-vested portion when the schedule
    /// is rebased while a vest is in progress. Returning 0 in that transient window keeps
    /// totalAssets() live; the missing piece is reaccounted automatically once enough
    /// wall-clock time passes. The clamp can only understate the vault, never overstate.
    /// @custom:access Public
    function balanceOf() public view returns (uint256) {
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        if (data.vestingTime == 0) {
            return IERC20(UNDERLYING_TOKEN()).balanceOf(address(this));
        }

        if (data.updateBalanceTimestamp == 0) {
            return 0;
        }

        uint256 vested = RewardsClaimManagersStorageLib.vestedAt(
            data.lastUpdateBalance,
            data.vestingTime,
            data.updateBalanceTimestamp,
            block.timestamp
        );

        return vested > data.transferredTokens ? vested - data.transferredTokens : 0;
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
        if (asset_ == UNDERLYING_TOKEN()) {
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

        PlasmaVault(PLASMA_VAULT()).claimRewards(calls_);
    }

    /// @notice Updates the balance and vesting schedule
    /// @dev Transfers available tokens to Plasma Vault and updates vesting data
    /// @custom:access UPDATE_REWARDS_BALANCE_ROLE
    function updateBalance() external restricted {
        uint256 balance = balanceOf();

        if (balance > 0) {
            IERC20(UNDERLYING_TOKEN()).safeTransfer(PLASMA_VAULT(), balance);
        }

        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        data.updateBalanceTimestamp = block.timestamp.toUint32();
        data.lastUpdateBalance = IERC20(UNDERLYING_TOKEN()).balanceOf(address(this)).toUint128();
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

        IERC20(UNDERLYING_TOKEN()).safeTransfer(PLASMA_VAULT(), balance);
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
    /// @dev When called mid-flight (transferredTokens > 0 and lastUpdateBalance > 0), reverts
    /// with UnsafeVestingTime when the requested duration would force balanceOf() into the
    /// clamp window where vested_now < transferredTokens. The caller should either invoke
    /// updateBalance() first (drain & reset) or use rescheduleVesting() to rebase the curve
    /// in place without moving tokens.
    /// @custom:access ATOMIST_ROLE
    function setupVestingTime(uint256 vestingTime_) external restricted {
        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        if (data.transferredTokens != 0 && data.lastUpdateBalance != 0) {
            uint256 elapsed = block.timestamp > data.updateBalanceTimestamp
                ? block.timestamp - data.updateBalanceTimestamp
                : 0;

            // Max vt' s.t. last * elapsed / vt' >= transferred
            //  <=>  vt' <= elapsed * last / transferred
            // transferredTokens != 0 guaranteed by the outer guard.
            uint256 maxSafeVestingTime = (elapsed * uint256(data.lastUpdateBalance)) /
                uint256(data.transferredTokens);

            if (vestingTime_ > maxSafeVestingTime) {
                revert UnsafeVestingTime(vestingTime_, maxSafeVestingTime);
            }
        }

        RewardsClaimManagersStorageLib.setupVestingTime(vestingTime_);
    }

    /// @notice Rebase the vesting schedule in place without transferring tokens to the Plasma Vault.
    /// @dev Use case: governance changes the vesting length but totalAssets() must stay continuous
    /// at this block (e.g. fee snapshot, oracle freeze). Caller computes the new anchor off-chain as
    ///     t0' = block.timestamp - ceil(transferredTokens * newVestingTime / lastUpdateBalance)
    /// when the goal is to lengthen the curve while keeping totalAssets continuous. Reverts when the
    /// proposed (newVestingTime_, newUpdateBalanceTimestamp_) tuple would force balanceOf() to clamp
    /// at block.timestamp.
    /// @param newVestingTime_ New vesting duration in seconds. Must be > 0.
    /// @param newUpdateBalanceTimestamp_ New anchor timestamp for the linear curve. Must be > 0 and <= block.timestamp.
    /// Zero is rejected because balanceOf() treats updateBalanceTimestamp == 0 as an uninitialized
    /// sentinel and returns 0 — accepting a zero anchor here would silently zero out totalAssets()
    /// even though the vestedAt() invariant guard would pass.
    /// @custom:access ATOMIST_ROLE
    function rescheduleVesting(
        uint32 newVestingTime_,
        uint32 newUpdateBalanceTimestamp_
    ) external restricted {
        if (newVestingTime_ == 0) revert InvalidVestingTime();
        if (newUpdateBalanceTimestamp_ == 0) revert InvalidTimestamp();
        if (uint256(newUpdateBalanceTimestamp_) > block.timestamp) revert InvalidTimestamp();

        VestingData memory data = RewardsClaimManagersStorageLib.getVestingData();

        uint256 vestedAfter = RewardsClaimManagersStorageLib.vestedAt(
            uint256(data.lastUpdateBalance),
            newVestingTime_,
            newUpdateBalanceTimestamp_,
            block.timestamp
        );

        if (vestedAfter < uint256(data.transferredTokens)) {
            revert UnsafeReschedule(
                uint256(newVestingTime_),
                uint256(newUpdateBalanceTimestamp_),
                vestedAfter,
                uint256(data.transferredTokens)
            );
        }

        data.vestingTime = newVestingTime_;
        data.updateBalanceTimestamp = newUpdateBalanceTimestamp_;
        RewardsClaimManagersStorageLib.setVestingData(data);

        emit VestingRescheduled(
            uint256(newVestingTime_),
            uint256(newUpdateBalanceTimestamp_),
            uint256(data.transferredTokens),
            uint256(data.lastUpdateBalance)
        );
    }

    /// @notice Internal function to get the message sender from context
    /// @return The address of the message sender
    function _msgSender() internal view override returns (address) {
        return _getSenderFromContext();
    }
}
