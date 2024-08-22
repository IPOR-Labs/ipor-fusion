// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice RedemptionLocks storage structure
/// @custom:storage-location erc7201:io.ipor.managers.access.RedemptionLocks
struct RedemptionLocks {
    mapping(address acount => uint256 depositTime) redemptionLock;
}

/// @custom:storage-location erc7201:io.ipor.managers.access.MinimalExecutionDelayForRole
struct MinimalExecutionDelayForRole {
    mapping(uint64 roleId => uint256 delay) delays;
}

/// @custom:storage-location erc7201:io.ipor.managers.access.RedemptionDelay
struct RedemptionDelay {
    uint256 redemptionDelay;
}

/// @custom:storage-location erc7201:io.ipor.managers.access.InitializationFlag
struct InitializationFlag {
    // @dev if greater than 0 then initialized
    uint256 initialized;
}

/// @title Storage library for Managers contracts
library IporFusionAccessManagersStorageLib {
    using SafeCast for uint256;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.RedemptionDelay")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REDEMPTION_DELAY = 0x145eef5574c3cce4d2653445e6a5a4d0b02eafca2d8fced992bac1eca819d500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.RedemptionLocks")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant REDEMPTION_LOCKS = 0x5e07febb5bd598f6b55406c9bf939d497fd39a2dbc2b5891f20f6640c3f32500;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.MinimalExecutionDelayForRole")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant MINIMAL_EXECUTION_DELAY_FOR_ROLE =
        0x2e44a6c6f75b62bc581bae68fca3a6629eb7343eef230a6702d4acd6389fd600;

    /// @dev keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.InitializationFlag")) - 1)) & ~bytes32(uint256(0xff));
    bytes32 private constant INITIALIZATION_FLAG = 0x25e922da7c41a5d012dbc2479dd6a7bd57760f359ea3a3be13608d287fc89400;

    event RedemptionDelayUpdated(uint256 redemptionDelay);
    event RedemptionDelayForAccountUpdated(address account, uint256 redemptionDelay);

    /// @notice gets the  Ipor Fusion Access Manager initialization flag storage pointer
    /// @return initializationFlag the storage pointer to the Ipor Fusion Access Manager initialization flag
    function getInitializationFlag() internal view returns (InitializationFlag storage initializationFlag) {
        assembly {
            initializationFlag.slot := INITIALIZATION_FLAG
        }
    }

    /// @notice gets the  minimal execution delay for role storage pointer
    /// @return minimalExecutionDelayForRole the storage pointer to the minimal execution delay for role
    function getMinimalExecutionDelayForRole()
        internal
        pure
        returns (MinimalExecutionDelayForRole storage minimalExecutionDelayForRole)
    {
        assembly {
            minimalExecutionDelayForRole.slot := MINIMAL_EXECUTION_DELAY_FOR_ROLE
        }
    }

    /// @notice gets the  redemption delay storage pointer
    /// @return redemptionDelay the storage pointer to the redemption delay
    function getRedemptionDelay() internal view returns (RedemptionDelay storage redemptionDelay) {
        assembly {
            redemptionDelay.slot := REDEMPTION_DELAY
        }
    }

    /// @notice sets the redemption delay
    /// @param redemptionDelay_ the redemption delay in seconds
    /// @dev Redemption delay is the time an account is locked for withdraw and redeem functions after deposit or mint functions
    function setRedemptionDelay(uint256 redemptionDelay_) internal {
        getRedemptionDelay().redemptionDelay = redemptionDelay_;
        emit RedemptionDelayUpdated(redemptionDelay_);
    }

    /// @notice gets the redemption locks storage pointer
    /// @return redemptionLocks the storage pointer to the redemption locks
    function getRedemptionLocks() internal view returns (RedemptionLocks storage redemptionLocks) {
        assembly {
            redemptionLocks.slot := REDEMPTION_LOCKS
        }
    }

    /// @notice sets the redemption locks for an account
    /// @param account_ the account to set the redemption locks for
    /// @dev When deposit or mint functions are called, the account is locked for withdraw and redeem functions for a specific time defined by the redemption delay
    function setRedemptionLocks(address account_) internal {
        uint256 redemptionDelay = getRedemptionDelay().redemptionDelay.toUint32();
        if (redemptionDelay == 0) {
            return;
        }
        RedemptionLocks storage redemptionLocks = getRedemptionLocks();
        uint256 redemptionLock = uint256(block.timestamp) + redemptionDelay;
        redemptionLocks.redemptionLock[account_] = redemptionLock;
        emit RedemptionDelayForAccountUpdated(account_, redemptionLock);
    }
}
