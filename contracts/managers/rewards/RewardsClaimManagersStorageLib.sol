// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {VestingData} from "../../interfaces/IRewardsClaimManager.sol";

/// @title RewardsClaimManagersStorageLib
/// @notice Storage library for managing vesting data of claimed rewards in the IPOR Protocol
/// @dev Implements storage patterns for vesting schedule management and token transfer tracking
library RewardsClaimManagersStorageLib {
    using SafeCast for uint256;

    /// @dev Storage slot for vesting data. Computed as:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.VestingData")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VESTING_DATA = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;

    /// @notice Emitted when vesting data is updated
    /// @param transferredTokens Amount of tokens that have been transferred to the Plasma Vault
    /// @param balanceOnLastUpdate Balance of tokens at the last update
    /// @param vestingTime Duration of the vesting period in seconds
    /// @param lastUpdateBalance Timestamp of the last balance update
    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 balanceOnLastUpdate,
        uint32 vestingTime,
        uint32 lastUpdateBalance
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
    function getVestingData() internal view returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := VESTING_DATA
        }
    }

    /// @notice Updates all vesting parameters
    /// @param vestingData_ New vesting configuration to be stored
    /// @dev Updates all fields of the vesting data struct and emits a VestingDataUpdated event
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
}
