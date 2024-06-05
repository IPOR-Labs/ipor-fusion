// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @custom:storage-location erc7201:io.ipor.electron.FoundsReleaseData
struct VestingData {
    /// @dev value in seconds
    uint32 vestingTime;
    uint32 updateBalanceTimestamp;
    uint128 transferredTokens;
    uint128 lastUpdateBalance;
}

/// @title Storage
library ManagersStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.ElectronVestingData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VESTING_DATA = 0x33420bf4a5ed1298cf2d2d9b469b5e8a16f2012dd073a10231f768e03ad9f900;

    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 balanceOnLastUpdate,
        uint32 vestingTime,
        uint32 lastUpdateBalance
    );
    event VestingTimeUpdated(uint256 vestingTime);
    event TransferredTokensUpdated(uint128 transferredTokens);

    function getVestingData() internal view returns (VestingData memory) {
        return _getVestingData();
    }

    function setVestingData(VestingData memory vestingData_) internal {
        VestingData storage vestingData = _getVestingData();
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

    function setupVestingTime(uint256 vesting_) internal {
        _getVestingData().vestingTime = vesting_.toUint32();
        emit VestingTimeUpdated(vesting_);
    }

    function updateTransferredTokens(uint256 amount_) internal {
        VestingData storage vestingData = _getVestingData();
        uint128 releasedTokens = vestingData.transferredTokens + amount_.toUint128();
        vestingData.transferredTokens = releasedTokens;
        emit TransferredTokensUpdated(releasedTokens);
    }

    function _getVestingData() private pure returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := VESTING_DATA
        }
    }
}
