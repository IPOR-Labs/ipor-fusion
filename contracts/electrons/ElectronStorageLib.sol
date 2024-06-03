// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @custom:storage-location erc7201:io.ipor.electron.FoundsReleaseData
struct VestingData {
    /// @dev value in seconds
    uint32 vesting;
    uint32 updateBalanceTimestamp;
    uint128 releasedTokens;
    uint128 balanceOnLastUpdate;
}

/// @title Storage
library ElectronStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.ElectronVestingData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VESTING_DATA = 0x33420bf4a5ed1298cf2d2d9b469b5e8a16f2012dd073a10231f768e03ad9f900;

    event VestingDataUpdated(
        uint128 releasedTokens,
        uint128 balanceOnLastUpdate,
        uint32 vesting,
        uint32 updateBalanceTimestamp
    );
    event VestingUpdated(uint256 releaseTokensDelay);
    event ReleasedTokensUpdated(uint128 releaseTokensDelay);

    function _getVestingData() private pure returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := VESTING_DATA
        }
    }

    function getVestingData() internal view returns (VestingData memory) {
        return _getVestingData();
    }

    function setVestingData(VestingData memory vestingData_) internal {
        VestingData storage foundsReleaseData = _getVestingData();
        foundsReleaseData.vesting = vestingData_.vesting;
        foundsReleaseData.updateBalanceTimestamp = vestingData_.updateBalanceTimestamp;
        foundsReleaseData.releasedTokens = vestingData_.releasedTokens;
        foundsReleaseData.balanceOnLastUpdate = vestingData_.balanceOnLastUpdate;
        emit VestingDataUpdated(
            foundsReleaseData.releasedTokens,
            foundsReleaseData.balanceOnLastUpdate,
            foundsReleaseData.vesting,
            foundsReleaseData.updateBalanceTimestamp
        );
    }

    function setupVesting(uint256 vesting_) internal {
        _getVestingData().vesting = vesting_.toUint32();
        emit VestingUpdated(vesting_);
    }

    function updateReleasedTokens(uint256 amount_) internal {
        VestingData storage foundsReleaseData = _getVestingData();
        uint128 releasedTokens = foundsReleaseData.releasedTokens + amount_.toUint128();
        foundsReleaseData.releasedTokens = releasedTokens;
        emit ReleasedTokensUpdated(releasedTokens);
    }
}
