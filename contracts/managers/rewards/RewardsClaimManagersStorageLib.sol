// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {VestingData} from "../../interfaces/IRewardsClaimManager.sol";

/// @title Storage library for Managers contracts, responsible for storing the claimed rewards vesting data
library RewardsClaimManagersStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.rewards.VestingData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VESTING_DATA = 0x6ab1bcc6104660f940addebf2a0f1cdfdd8fb6e9a4305fcd73bc32a2bcbabc00;

    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 balanceOnLastUpdate,
        uint32 vestingTime,
        uint32 lastUpdateBalance
    );
    event VestingTimeUpdated(uint256 vestingTime);
    event TransferredTokensUpdated(uint128 transferredTokens);

    /// @notice Retrieves the vesting data storage pointer
    /// @return foundsReleaseData The storage pointer to the vesting data
    function getVestingData() internal view returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := VESTING_DATA
        }
    }

    /// @notice Sets the vesting data
    /// @param vestingData_ The vesting data to be set
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

    /// @notice Sets the vesting time
    /// @param vesting_ The vesting time to be set, in seconds
    /// @dev Vesting time is the time when the vesting of underlying tokens placed on Rewards Claim Manager are vested in linear fashion
    function setupVestingTime(uint256 vesting_) internal {
        getVestingData().vestingTime = vesting_.toUint32();
        emit VestingTimeUpdated(vesting_);
    }

    /// @notice Updates the transferred tokens
    /// @param amount_ The amount of tokens to be added to the transferred tokens
    /// @dev Transferred tokens are the tokens that have been transferred from RewardsClaimManager to the Plasma Vault
    function updateTransferredTokens(uint256 amount_) internal {
        VestingData storage vestingData = getVestingData();
        uint128 releasedTokens = vestingData.transferredTokens + amount_.toUint128();
        vestingData.transferredTokens = releasedTokens;
        emit TransferredTokensUpdated(releasedTokens);
    }
}
