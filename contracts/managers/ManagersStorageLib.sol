// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @custom:storage-location erc7201:io.ipor.menagers.FoundsReleaseData
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

struct MinimalExecutionDelayForRole {
    mapping(uint64 roleId => uint256 delay) delays;
}

struct RedemptionDelay {
    uint256 redemptionDelay;
}

struct PlasmaVaultAddress {
    address plasmaVault;
}

struct InitializeAccessManager {
    // @dev if grate than 0 then initialized
    uint256 initialized;
}

/// @title Storage library for Managers contracts
library ManagersStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.VestingData")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REWARDS_CLAIM_MANAGER_VESTING_DATA =
        0x0d045b5703684afaa183a07037de996bd8cd6d6b3ff96656a7ee811227ddf700;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.RedemptionDelay")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ACCESS_MANAGER_REDEMPTION_DELAY =
        0xcd3f64412f7e3e03fd4a055a0b9215638f10bd88b6e2999623a4fbce73568b00;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.RedemptionLocks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ACCESS_MANAGER_REDEMPTION_LOCKS =
        0x1df8c3be97c2c624569b6b4d642cde88d3084fa39c37b3ca0e61dbd22d5c4200;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.minimalExecutionDelayForRole")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ACCESS_MANAGER_MINIMAL_EXECUTION_DELAY_FOR_ROLE =
        0x97af39007ec695dbf3f648be640f71c99bfc72f6f0c1a011cea5df1b93824400;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.initializeAccessManager")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant ACCESS_MANAGER_INITIALIZE =
        0xbe9386785e99777544cae08d8688b2ce0aed369d4b6cb68200fcd245c8f21e00;

    event VestingDataUpdated(
        uint128 transferredTokens,
        uint128 balanceOnLastUpdate,
        uint32 vestingTime,
        uint32 lastUpdateBalance
    );
    event VestingTimeUpdated(uint256 vestingTime);
    event TransferredTokensUpdated(uint128 transferredTokens);
    event RedemptionDelayUpdated(uint256 redemptionDelay);
    event RedemptionDelayForAccountUpdated(address account, uint256 redemptionDelay);

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

    function getRedemptionDelay() internal view returns (RedemptionDelay storage) {
        return _getRedemptionDelay();
    }

    function getRedemptionLocks() internal view returns (RedemptionLocks storage) {
        return _getRedemptionLocks();
    }

    function getInitializeAccessManager() internal view returns (InitializeAccessManager storage initialize) {
        assembly {
            initialize.slot := ACCESS_MANAGER_INITIALIZE
        }
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
        uint256 redemptionLock = uint256(block.timestamp) + redemptionDelay;
        redemptionLocks.redemptionLock[account_] = redemptionLock;
        emit RedemptionDelayForAccountUpdated(account_, redemptionLock);
    }

    function _getVestingData() private pure returns (VestingData storage foundsReleaseData) {
        assembly {
            foundsReleaseData.slot := REWARDS_CLAIM_MANAGER_VESTING_DATA
        }
    }

    function _getRedemptionDelay() private pure returns (RedemptionDelay storage redemptionDelay) {
        assembly {
            redemptionDelay.slot := ACCESS_MANAGER_REDEMPTION_DELAY
        }
    }

    function _getRedemptionLocks() private pure returns (RedemptionLocks storage redemptionLocks) {
        assembly {
            redemptionLocks.slot := ACCESS_MANAGER_REDEMPTION_LOCKS
        }
    }

    function _getMinimalExecutionDelayForRole()
        internal
        pure
        returns (MinimalExecutionDelayForRole storage minimalExecutionDelayForRole)
    {
        assembly {
            minimalExecutionDelayForRole.slot := ACCESS_MANAGER_MINIMAL_EXECUTION_DELAY_FOR_ROLE
        }
    }
}
