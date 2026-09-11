// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/**
 * @title Redemption Lock Start Times Storage Structure
 * @notice Stores the moment each account last deposited or minted (the start of its redemption lock)
 * @dev The effective unlock timestamp is computed at read time as
 * lockStartTime + the current redemption delay, so the currently configured delay always governs
 * @custom:storage-location erc7201:io.ipor.managers.access.RedemptionLockStartTimes
 */
struct RedemptionLockStartTimes {
    /// @notice Maps user addresses to the timestamp of their last deposit or mint
    /// @dev Recorded unconditionally, even when the redemption delay is 0, so a later
    /// increase of the delay reaches accounts that deposited while it was 0
    mapping(address account => uint256 lockStartTime) lockStartTime;
}

/**
 * @title Redemption Delay Storage Structure
 * @notice Stores the vault-wide redemption delay applied to every account's lock start time
 * @dev Changeable after vault creation via PlasmaVaultGovernance.setRedemptionDelay, which forwards to
 * IporFusionAccessManager.setRedemptionDelay (TECH_PLASMA_VAULT_ROLE)
 * @custom:storage-location erc7201:io.ipor.managers.access.RedemptionDelay
 */
struct RedemptionDelay {
    /// @notice The current redemption delay in seconds
    uint256 redemptionDelayInSeconds;
}

/**
 * @title Minimal Execution Delay Storage Structure
 * @notice Stores role-specific execution delays for timelock functionality
 * @dev Uses ERC-7201 namespaced storage pattern
 * @custom:storage-location erc7201:io.ipor.managers.access.MinimalExecutionDelayForRole
 */
struct MinimalExecutionDelayForRole {
    /// @notice Maps role IDs to their required execution delays
    mapping(uint64 roleId => uint256 delay) delays;
}

/**
 * @title Initialization Flag Storage Structure
 * @notice Tracks initialization status to prevent multiple initializations
 * @dev Uses ERC-7201 namespaced storage pattern
 * @custom:storage-location erc7201:io.ipor.managers.access.InitializationFlag
 */
struct InitializationFlag {
    /// @notice Initialization status flag
    /// @dev Value greater than 0 indicates initialized state
    uint256 initialized;
}

/**
 * @title IPOR Fusion Access Managers Storage Library
 * @notice Library managing storage layouts for access control and redemption mechanisms
 * @dev Implements ERC-7201 storage pattern for namespace isolation
 * @custom:security-contact security@ipor.io
 */
library IporFusionAccessManagersStorageLib {
    /// @notice Storage slot for RedemptionLockStartTimes
    /// @dev Replaces the retired namespace io.ipor.managers.access.RedemptionLocks (slot
    /// 0x5e07febb5bd598f6b55406c9bf939d497fd39a2dbc2b5891f20f6640c3f32500, held absolute unlock
    /// timestamps fixed at deposit time); do not re-derive that namespace
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.RedemptionLockStartTimes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REDEMPTION_LOCK_START_TIMES =
        0x83e7bafd2a5059a7a3f8f00883c599ce24355cc422725b4bf7e796d03c954a00;

    /// @notice Storage slot for RedemptionDelay
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.RedemptionDelay")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REDEMPTION_DELAY = 0x145eef5574c3cce4d2653445e6a5a4d0b02eafca2d8fced992bac1eca819d500;

    /// @notice Storage slot for MinimalExecutionDelayForRole
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.MinimalExecutionDelayForRole")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MINIMAL_EXECUTION_DELAY_FOR_ROLE =
        0x2e44a6c6f75b62bc581bae68fca3a6629eb7343eef230a6702d4acd6389fd600;

    /// @notice Storage slot for InitializationFlag
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.InitializationFlag")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZATION_FLAG = 0x25e922da7c41a5d012dbc2479dd6a7bd57760f359ea3a3be13608d287fc89400;

    /**
     * @notice Retrieves the initialization flag storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return initializationFlag Storage pointer to the initialization flag
     */
    function getInitializationFlag() internal pure returns (InitializationFlag storage initializationFlag) {
        assembly {
            initializationFlag.slot := INITIALIZATION_FLAG
        }
    }

    /**
     * @notice Retrieves the minimal execution delay storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return minimalExecutionDelayForRole Storage pointer to the execution delays mapping
     */
    function getMinimalExecutionDelayForRole()
        internal
        pure
        returns (MinimalExecutionDelayForRole storage minimalExecutionDelayForRole)
    {
        assembly {
            minimalExecutionDelayForRole.slot := MINIMAL_EXECUTION_DELAY_FOR_ROLE
        }
    }

    /**
     * @notice Retrieves the redemption lock start times storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return redemptionLockStartTimes Storage pointer to the redemption lock start times mapping
     */
    function getRedemptionLockStartTimes()
        internal
        pure
        returns (RedemptionLockStartTimes storage redemptionLockStartTimes)
    {
        assembly {
            redemptionLockStartTimes.slot := REDEMPTION_LOCK_START_TIMES
        }
    }

    /**
     * @notice Retrieves the current vault-wide redemption delay
     * @return The redemption delay in seconds
     */
    function getRedemptionDelay() internal view returns (uint256) {
        return _getRedemptionDelay().redemptionDelayInSeconds;
    }

    /**
     * @notice Sets the vault-wide redemption delay
     * @param redemptionDelayInSeconds_ The new redemption delay in seconds
     * @dev Validation (upper bound, access control) is performed by the caller
     */
    function setRedemptionDelay(uint256 redemptionDelayInSeconds_) internal {
        _getRedemptionDelay().redemptionDelayInSeconds = redemptionDelayInSeconds_;
    }

    /**
     * @notice Retrieves the redemption lock start time for an account
     * @param account_ The address to read the lock start time for
     * @return The timestamp of the account's last deposit or mint, 0 if the account never deposited
     */
    function getRedemptionLockStartTime(address account_) internal view returns (uint256) {
        return getRedemptionLockStartTimes().lockStartTime[account_];
    }

    /**
     * @notice Records the redemption lock start time for an account after deposit or mint operations
     * @dev Stores block.timestamp unconditionally, even when the redemption delay is currently 0,
     * so a later increase of the delay applies to this account as well. The effective unlock time
     * is computed at read time against the current redemption delay.
     * @param account_ The address to record the redemption lock start time for
     * @custom:security This function helps prevent potential manipulation through quick deposits and withdrawals
     */
    function setRedemptionLockStartTime(address account_) internal {
        getRedemptionLockStartTimes().lockStartTime[account_] = block.timestamp;
    }

    /**
     * @notice Retrieves the redemption delay storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return redemptionDelay Storage pointer to the redemption delay
     */
    function _getRedemptionDelay() private pure returns (RedemptionDelay storage redemptionDelay) {
        assembly {
            redemptionDelay.slot := REDEMPTION_DELAY
        }
    }
}
