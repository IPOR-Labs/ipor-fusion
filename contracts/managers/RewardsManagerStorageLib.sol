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

struct RedemptionLocks {
    mapping(address acount => uint256 depositTime) redemptionLock;
}

struct RedemptionDelay {
    uint256 redemptionDelay;
}

struct PlasmaVaultAddress {
    address plasmaVault;
}

/// @title Storage
library RewardsManagerStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.ElectronVestingData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant VESTING_DATA = 0x33420bf4a5ed1298cf2d2d9b469b5e8a16f2012dd073a10231f768e03ad9f900;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.redemptionDelay")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REDEMPTION_DELAY = 0x88ed68bfe7fb6e54dd3b39452c38a9866e5bb6339724eb20da899aa3bb999700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.redemptionLocks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REDEMPTION_LOCKS = 0x64f822be72115f7a1b8b1e01aaffa6c3b18be496e0df14d2a543d41dff19e400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.ElectronPlasmaVault")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant PLASMA_VAULT = 0x1347d33dc8b9c73cd60c6cf9da27f486ee0dbb247e728b1acd4ccea4b4cd8700;

    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 balanceOnLastUpdate,
        uint32 vestingTime,
        uint32 lastUpdateBalance
    );
    event VestingTimeUpdated(uint256 vestingTime);
    event TransferredTokensUpdated(uint128 transferredTokens);

    event ReleasedTokensUpdated(uint128 releaseTokensDelay);
    event RedemptionDelayUpdated(uint256 redemptionDelay);
    event RedemptionLocksUpdated(address account, uint256 locksTime);

    function _getRedemptionDelay() private pure returns (RedemptionDelay storage redemptionDelay) {
        assembly {
            redemptionDelay.slot := REDEMPTION_DELAY
        }
    }

    function _getRedemptionLocks() private pure returns (RedemptionLocks storage redemptionLocks) {
        assembly {
            redemptionLocks.slot := REDEMPTION_LOCKS
        }
    }

    function getVestingData() internal view returns (VestingData memory) {
        return _getVestingData();
    }

    function getRedemptionDelay() internal view returns (RedemptionDelay storage) {
        return _getRedemptionDelay();
    }

    function getRedemptionLocks() internal view returns (RedemptionLocks storage) {
        return _getRedemptionLocks();
    }

    function setRedemptionDelay(uint256 redemptionDelay_) internal {
        _getRedemptionDelay().redemptionDelay = redemptionDelay_;
        emit RedemptionDelayUpdated(redemptionDelay_);
    }

    function setRedemptionLocks(address account_) internal {
        uint256 redemptionDelay = _getRedemptionDelay().redemptionDelay.toUint32();
        if (redemptionDelay == 0) {
            return;
        }
        RedemptionLocks storage redemptionLocks = _getRedemptionLocks();
        redemptionLocks.redemptionLock[account_] = uint256(block.timestamp) + redemptionDelay;
    }

    function setVestingData(VestingData memory vestingData_) internal {
        VestingData storage foundsReleaseData = _getVestingData();
        foundsReleaseData.vestingTime = vestingData_.vestingTime;
        foundsReleaseData.updateBalanceTimestamp = vestingData_.updateBalanceTimestamp;
        foundsReleaseData.transferredTokens = vestingData_.transferredTokens;
        foundsReleaseData.lastUpdateBalance = vestingData_.lastUpdateBalance;
        emit VestingDataUpdated(
            foundsReleaseData.transferredTokens,
            foundsReleaseData.lastUpdateBalance,
            foundsReleaseData.vestingTime,
            foundsReleaseData.updateBalanceTimestamp
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
