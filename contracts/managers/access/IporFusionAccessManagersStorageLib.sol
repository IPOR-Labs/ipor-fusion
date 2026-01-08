// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IIporFusionAccessManager} from "../../interfaces/IIporFusionAccessManager.sol";

/**
 * @title Redemption Locks Storage Structure
 * @notice Manages time-based locks for redemption operations per account
 * @dev Uses ERC-7201 namespaced storage pattern to prevent storage collisions
 * @custom:storage-location erc7201:io.ipor.managers.access.RedemptionLocks
 */
struct RedemptionLocks {
    /// @notice Maps user addresses to their deposit timestamp
    /// @dev Used to enforce redemption delays after deposits
    mapping(address acount => uint256 depositTime) redemptionLock;
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
    using SafeCast for uint256;

    /// @notice Storage slot for RedemptionLocks
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.RedemptionLocks")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant REDEMPTION_LOCKS = 0x5e07febb5bd598f6b55406c9bf939d497fd39a2dbc2b5891f20f6640c3f32500;

    /// @notice Storage slot for MinimalExecutionDelayForRole
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.MinimalExecutionDelayForRole")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant MINIMAL_EXECUTION_DELAY_FOR_ROLE =
        0x2e44a6c6f75b62bc581bae68fca3a6629eb7343eef230a6702d4acd6389fd600;

    /// @notice Storage slot for InitializationFlag
    /// @dev Computed as: keccak256(abi.encode(uint256(keccak256("io.ipor.managers.access.InitializationFlag")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant INITIALIZATION_FLAG = 0x25e922da7c41a5d012dbc2479dd6a7bd57760f359ea3a3be13608d287fc89400;

    /// @notice Emitted when an account's redemption delay is updated
    /// @param account The address of the affected account
    /// @param redemptionDelay The new redemption delay timestamp
    event RedemptionDelayForAccountUpdated(address account, uint256 redemptionDelay);

    /**
     * @notice Retrieves the initialization flag storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return initializationFlag Storage pointer to the initialization flag
     */
    function getInitializationFlag() internal view returns (InitializationFlag storage initializationFlag) {
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
     * @notice Retrieves the redemption locks storage pointer
     * @dev Uses assembly to access the predetermined storage slot
     * @return redemptionLocks Storage pointer to the redemption locks mapping
     */
    function getRedemptionLocks() internal view returns (RedemptionLocks storage redemptionLocks) {
        assembly {
            redemptionLocks.slot := REDEMPTION_LOCKS
        }
    }

    /**
     * @notice Sets redemption lock for an account after deposit or mint operations
     * @dev Enforces a time-based lock to prevent immediate withdrawals after deposits
     * @param account_ The address to set the redemption lock for
     * @custom:security This function helps prevent potential manipulation through quick deposits and withdrawals
     */
    function setRedemptionLocks(address account_) internal {
        uint256 redemptionDelay = IIporFusionAccessManager(address(this)).REDEMPTION_DELAY_IN_SECONDS();
        if (redemptionDelay == 0) {
            return;
        }
        RedemptionLocks storage redemptionLocks = getRedemptionLocks();
        uint256 redemptionLock = uint256(block.timestamp) + redemptionDelay;
        redemptionLocks.redemptionLock[account_] = redemptionLock;
        emit RedemptionDelayForAccountUpdated(account_, redemptionLock);
    }
}
