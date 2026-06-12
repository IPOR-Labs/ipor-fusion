// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {VestingData} from "../../interfaces/IRewardsClaimManager.sol";

/// @title RewardsClaimManagersStorageLib
/// @notice Storage library for managing vesting data of claimed rewards in the IPOR Protocol
/// @dev Implements storage patterns for vesting schedule management and token transfer tracking
library RewardsClaimManagersStorageLib {
    using SafeCast for uint256;

    /// @dev Storage slot for vesting data. Computed as:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.VestingData")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VESTING_DATA = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;

    /// @dev Storage slot for underlying token address. Computed as:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.UnderlyingToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant UNDERLYING_TOKEN_SLOT = 0x96962a50a0c0e57d12771ca8fb38d59142b19de93fdd10189d0e6674c3c52600;

    /// @dev Storage slot for plasma vault address. Computed as:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.PlasmaVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant PLASMA_VAULT_SLOT = 0x2d4767721b6a66348474dafa99902e10eaba3139521ee5498349612c152c8100;

    /// @notice Emitted when vesting data is updated
    /// @param transferredTokens Amount of tokens that have been transferred to the Plasma Vault
    /// @param lastUpdateBalance Balance of tokens at the last update
    /// @param vestingTime Duration of the vesting period in seconds
    /// @param updateBalanceTimestamp Timestamp of the last balance update
    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 lastUpdateBalance,
        uint32 vestingTime,
        uint32 updateBalanceTimestamp
    );

    /// @notice Emitted when vesting time is updated
    /// @param vestingTime New vesting duration in seconds
    event VestingTimeUpdated(uint256 vestingTime);

    /// @notice Emitted when transferred tokens amount is updated
    /// @param transferredTokens New total amount of transferred tokens
    event TransferredTokensUpdated(uint128 transferredTokens);

    /// @notice Retrieves the vesting data storage pointer
    /// @return foundsReleaseData Storage pointer to the vesting data struct
    /// @dev Uses assembly to access the predetermined storage slot
    function getVestingData() internal pure returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := VESTING_DATA
        }
    }

    /// @notice Updates all vesting parameters
    /// @param vestingData_ New vesting configuration to be stored
    /// @dev Updates all fields of the vesting data struct and emits a VestingDataUpdated event.
    /// @dev The VestingDataUpdated event reports field values using their canonical struct names
    /// (transferredTokens, lastUpdateBalance, vestingTime, updateBalanceTimestamp).
    function setVestingData(VestingData memory vestingData_) internal {
        VestingData storage vestingData = getVestingData();
        vestingData.vestingTime = vestingData_.vestingTime;
        vestingData.updateBalanceTimestamp = vestingData_.updateBalanceTimestamp;
        vestingData.transferredTokens = vestingData_.transferredTokens;
        vestingData.lastUpdateBalance = vestingData_.lastUpdateBalance;
        emit VestingDataUpdated(
            vestingData.transferredTokens,
            vestingData.lastUpdateBalance,
            vestingData.vestingTime,
            vestingData.updateBalanceTimestamp
        );
    }

    /// @notice Configures the vesting duration
    /// @param vesting_ Duration of the vesting period in seconds
    /// @dev Updates the vesting time and emits a VestingTimeUpdated event
    /// @dev The vesting schedule is linear, meaning tokens are released uniformly over the vesting period
    function setupVestingTime(uint256 vesting_) internal {
        getVestingData().vestingTime = vesting_.toUint32();
        emit VestingTimeUpdated(vesting_);
    }

    /// @notice Records additional tokens transferred to the Plasma Vault
    /// @param amount_ Amount of tokens to add to the transferred tokens total
    /// @dev Updates the cumulative amount of transferred tokens and emits a TransferredTokensUpdated event
    /// @dev This function should be called whenever tokens are moved from RewardsClaimManager to the Plasma Vault
    function updateTransferredTokens(uint256 amount_) internal {
        VestingData storage vestingData = getVestingData();
        uint128 releasedTokens = vestingData.transferredTokens + amount_.toUint128();
        vestingData.transferredTokens = releasedTokens;
        emit TransferredTokensUpdated(releasedTokens);
    }

    /// @notice Gets the underlying token address from storage
    /// @return The address of the underlying token
    function getUnderlyingToken() internal view returns (address) {
        address token;
        assembly {
            token := sload(UNDERLYING_TOKEN_SLOT)
        }
        return token;
    }

    /// @notice Sets the underlying token address in storage
    /// @param token_ The address of the underlying token
    function setUnderlyingToken(address token_) internal {
        assembly {
            sstore(UNDERLYING_TOKEN_SLOT, token_)
        }
    }

    /// @notice Gets the plasma vault address from storage
    /// @return The address of the plasma vault
    function getPlasmaVault() internal view returns (address) {
        address vault;
        assembly {
            vault := sload(PLASMA_VAULT_SLOT)
        }
        return vault;
    }

    /// @notice Sets the plasma vault address in storage
    /// @param vault_ The address of the plasma vault
    function setPlasmaVault(address vault_) internal {
        assembly {
            sstore(PLASMA_VAULT_SLOT, vault_)
        }
    }

    /// @notice Linearly-vested portion of `lastUpdateBalance_` at `nowTs_` under the schedule
    /// defined by (vestingTime_, updateBalanceTimestamp_).
    /// @dev Single source of truth for the vesting curve. Used by balanceOf() to compute the
    /// claimable amount, by setupVestingTime() to derive the safe-boundary cap, and by
    /// rescheduleVesting() to verify the cross-field invariant before persisting a new schedule.
    /// @param lastUpdateBalance_ Balance snapshot taken at `updateBalanceTimestamp_`.
    /// @param vestingTime_ Vesting duration in seconds. Zero ⇒ returns 0 (handled by the caller).
    /// @param updateBalanceTimestamp_ Anchor timestamp of the linear curve.
    /// @param nowTs_ The reference timestamp against which to compute the vested portion.
    /// @return The vested portion of `lastUpdateBalance_`; clamped to `lastUpdateBalance_` once
    /// the elapsed time meets or exceeds `vestingTime_`.
    function vestedAt(
        uint256 lastUpdateBalance_,
        uint32 vestingTime_,
        uint32 updateBalanceTimestamp_,
        uint256 nowTs_
    ) internal pure returns (uint256) {
        if (vestingTime_ == 0 || nowTs_ <= updateBalanceTimestamp_) {
            return 0;
        }
        uint256 elapsed;
        unchecked {
            elapsed = nowTs_ - updateBalanceTimestamp_;
        }
        if (elapsed >= vestingTime_) {
            return lastUpdateBalance_;
        }
        return Math.mulDiv(lastUpdateBalance_, (elapsed * 1e18) / vestingTime_, 1e18);
    }
}
