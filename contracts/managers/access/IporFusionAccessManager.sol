// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IIporFusionAccessManager} from "../../interfaces/IIporFusionAccessManager.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {RedemptionDelayLib} from "./RedemptionDelayLib.sol";
import {PlasmaVault} from "../../vaults/PlasmaVault.sol";
import {RoleExecutionTimelockLib} from "./RoleExecutionTimelockLib.sol";
import {IporFusionAccessManagerInitializationLib, InitializationData} from "./IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../libraries/Roles.sol";

/**
 * @title IporFusionAccessManager
 * @notice Contract responsible for managing access control to the IporFusion protocol
 * @dev Extends OpenZeppelin's AccessManager with custom functionality for IPOR Fusion
 *
 * Role-based permissions:
 * - ADMIN_ROLE: Can initialize the contract and manage roles
 * - GUARDIAN_ROLE: Can cancel operations and update target closed status
 * - ATOMIST_ROLE: Can manage vault configurations and market settings
 * - PUBLIC_ROLE: Used for publicly accessible functions
 * - TECH_CONTEXT_MANAGER_ROLE: Technical role for context operations
 * - TECH_PLASMA_VAULT_ROLE: Technical role for plasma vault operations
 *
 * Function permissions:
 * - initialize: Restricted to ADMIN_ROLE
 * - updateTargetClosed: Restricted to GUARDIAN_ROLE
 * - convertToPublicVault: Restricted to TECH_PLASMA_VAULT_ROLE
 * - enableTransferShares: Restricted to TECH_PLASMA_VAULT_ROLE
 * - setMinimalExecutionDelaysForRoles: Restricted to TECH_PLASMA_VAULT_ROLE
 * - grantRole: Restricted to authorized roles (via onlyAuthorized)
 *
 * Security features:
 * - Role-based execution delays
 * - Redemption delay mechanism
 * - Guardian role for emergency actions
 * - Timelock controls for sensitive operations
 *
 */
contract IporFusionAccessManager is Initializable, IIporFusionAccessManager, AccessManager {
    error AccessManagedUnauthorized(address caller);
    error TooShortExecutionDelayForRole(uint64 roleId, uint32 executionDelay);
    error TooLongRedemptionDelay(uint256 redemptionDelayInSeconds);

    /// @notice Maximum allowed redemption delay in seconds (7 days)
    uint256 public constant MAX_REDEMPTION_DELAY_IN_SECONDS = 7 days;

    /// @notice Actual redemption delay in seconds for this instance
    // solhint-disable-next-line var-name-mixedcase
    uint256 public override REDEMPTION_DELAY_IN_SECONDS;

    /// @dev Flag to track custom schedule consumption
    bool private _customConsumingSchedule;

    /**
     * @notice Modifier to restrict function access to authorized callers
     * @dev Checks if the caller can execute the function and handles scheduled operations
     */
    modifier restricted() {
        _checkCanCall(_msgSender(), _msgData());
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    /// @notice Constructor that initializes the IporFusionAccessManager with an admin and redemption delay
    /// @dev Used when deploying directly without proxy
    /// @param initialAdmin_ The address that will be granted the ADMIN_ROLE
    /// @param redemptionDelayInSeconds_ The initial redemption delay period in seconds
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address initialAdmin_, uint256 redemptionDelayInSeconds_) AccessManager(initialAdmin_) initializer {
        _initialize(initialAdmin_, redemptionDelayInSeconds_);
    }

    /// @notice Initializes the IporFusionAccessManager with access control and redemption delay (for cloning)
    /// @param initialAdmin_ The address that will be granted the ADMIN_ROLE
    /// @param redemptionDelayInSeconds_ The initial redemption delay period in seconds
    /// @dev This method is called after cloning to initialize the contract
    /// @custom:access Only during initialization
    function proxyInitialize(address initialAdmin_, uint256 redemptionDelayInSeconds_) external initializer {
        _initialize(initialAdmin_, redemptionDelayInSeconds_);
    }

    /// @notice Private method containing the common initialization logic
    /// @param initialAdmin_ The initial admin address
    /// @param redemptionDelayInSeconds_ The redemption delay in seconds
    /// @dev This method is used by both constructor and proxyInitialize to avoid code duplication
    function _initialize(address initialAdmin_, uint256 redemptionDelayInSeconds_) private {
        if (redemptionDelayInSeconds_ > MAX_REDEMPTION_DELAY_IN_SECONDS) {
            revert TooLongRedemptionDelay(redemptionDelayInSeconds_);
        }
        REDEMPTION_DELAY_IN_SECONDS = redemptionDelayInSeconds_;
        _grantRole(ADMIN_ROLE, initialAdmin_, 0, 0);
    }

    /**
     * @notice Initializes the access manager with role configurations
     * @param initialData_ Initial configuration data for roles and permissions
     * @dev Sets up role hierarchies, function permissions, and execution delays
     * @custom:access Restricted to ADMIN_ROLE
     */
    function initialize(InitializationData calldata initialData_) external restricted {
        IporFusionAccessManagerInitializationLib.isInitialized();
        _revokeRole(ADMIN_ROLE, msg.sender);

        uint256 roleToFunctionsLength = initialData_.roleToFunctions.length;
        uint64[] memory roleIds = new uint64[](roleToFunctionsLength);
        uint256[] memory minimalDelays = new uint256[](roleToFunctionsLength);

        if (roleToFunctionsLength > 0) {
            for (uint256 i; i < roleToFunctionsLength; ++i) {
                _setTargetFunctionRole(
                    initialData_.roleToFunctions[i].target,
                    initialData_.roleToFunctions[i].functionSelector,
                    initialData_.roleToFunctions[i].roleId
                );
                roleIds[i] = initialData_.roleToFunctions[i].roleId;
                minimalDelays[i] = initialData_.roleToFunctions[i].minimalExecutionDelay;
                if (
                    initialData_.roleToFunctions[i].roleId != Roles.ADMIN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != Roles.GUARDIAN_ROLE &&
                    initialData_.roleToFunctions[i].roleId != Roles.PUBLIC_ROLE
                ) {
                    _setRoleGuardian(initialData_.roleToFunctions[i].roleId, Roles.GUARDIAN_ROLE);
                }
            }
        }
        RoleExecutionTimelockLib.setMinimalExecutionDelaysForRoles(roleIds, minimalDelays);

        uint256 adminRolesLength = initialData_.adminRoles.length;
        if (adminRolesLength > 0) {
            for (uint256 i; i < adminRolesLength; ++i) {
                _setRoleAdmin(initialData_.adminRoles[i].roleId, initialData_.adminRoles[i].adminRoleId);
            }
        }

        uint256 accountToRolesLength = initialData_.accountToRoles.length;
        if (accountToRolesLength > 0) {
            for (uint256 i; i < accountToRolesLength; ++i) {
                _grantRoleInternal(
                    initialData_.accountToRoles[i].roleId,
                    initialData_.accountToRoles[i].account,
                    initialData_.accountToRoles[i].executionDelay
                );
            }
        }
    }

    /**
     * @notice Checks if a caller can execute a function and updates state if needed
     * @param caller_ Address attempting to call the function
     * @param target_ Target contract address
     * @param selector_ Function selector being called
     * @return immediate Whether the call can be executed immediately
     * @return delay The required delay before execution
     * @custom:security Updates redemption delay state if applicable
     */
    function canCallAndUpdate(
        address caller_,
        address target_,
        bytes4 selector_
    ) external override restricted returns (bool immediate, uint32 delay) {
        RedemptionDelayLib.lockChecks(caller_, selector_);
        return super.canCall(caller_, target_, selector_);
    }

    /**
     * @notice Updates whether a target contract is closed for operations
     * @param target_ Target contract address
     * @param closed_ New closed status
     * @custom:access Restricted to GUARDIAN_ROLE
     */
    function updateTargetClosed(address target_, bool closed_) external override restricted {
        _setTargetClosed(target_, closed_);
    }

    /**
     * @notice Converts a vault to public access mode
     * @param vault_ Address of the vault to convert
     * @custom:access Restricted to TECH_PLASMA_VAULT_ROLE
     */
    function convertToPublicVault(address vault_) external override restricted {
        _setTargetFunctionRole(vault_, PlasmaVault.mint.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.deposit.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.depositWithPermit.selector, PUBLIC_ROLE);
    }

    /**
     * @notice Enables share transfer functionality for a vault
     * @param vault_ Address of the vault
     * @custom:access Restricted to TECH_PLASMA_VAULT_ROLE
     */
    function enableTransferShares(address vault_) external override restricted {
        _setTargetFunctionRole(vault_, PlasmaVault.transfer.selector, PUBLIC_ROLE);
        _setTargetFunctionRole(vault_, PlasmaVault.transferFrom.selector, PUBLIC_ROLE);
    }

    /**
     * @notice Sets minimal execution delays for specified roles
     * @param rolesIds_ Array of role IDs
     * @param delays_ Array of corresponding delays
     * @custom:access Restricted to TECH_PLASMA_VAULT_ROLE
     */
    function setMinimalExecutionDelaysForRoles(
        uint64[] calldata rolesIds_,
        uint256[] calldata delays_
    ) external override restricted {
        RoleExecutionTimelockLib.setMinimalExecutionDelaysForRoles(rolesIds_, delays_);
    }

    /**
     * @notice Grants a role to an account with a specified execution delay
     * @param roleId_ The role identifier to grant
     * @param account_ The account to receive the role
     * @param executionDelay_ The execution delay for the role operations
     * @dev Overrides AccessManager.grantRole to add execution delay validation
     * @custom:access
     * - Restricted to authorized roles via onlyAuthorized modifier
     * - Can only be called by the admin of the role being granted (e.g., ADMIN_ROLE can grant OWNER_ROLE, OWNER_ROLE can grant ATOMIST_ROLE)
     * - Role hierarchy must be followed according to Roles.sol documentation
     * @custom:security
     * - Validates that execution delay meets minimum requirements
     * - Role hierarchy must be respected (e.g., ADMIN_ROLE can grant OWNER_ROLE)
     * @custom:error TooShortExecutionDelayForRole if executionDelay_ is less than the minimum required
     */
    function grantRole(
        uint64 roleId_,
        address account_,
        uint32 executionDelay_
    ) public override(IAccessManager, AccessManager) onlyAuthorized {
        _grantRoleInternal(roleId_, account_, executionDelay_);
    }

    /**
     * @notice Retrieves the minimal execution delay configured for a specific role
     * @param roleId_ The role identifier to query
     * @return The minimal execution delay in seconds for the specified role
     * @dev This delay represents the minimum time that must pass between scheduling and executing an operation
     * @custom:access No access restrictions - can be called by anyone
     * @custom:security Used to enforce timelock restrictions on role operations
     */
    function getMinimalExecutionDelayForRole(uint64 roleId_) external view override returns (uint256) {
        return RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_);
    }

    /**
     * @notice Retrieves the lock time for a specific account
     * @param account_ The account address to query
     * @return The timestamp until which the account is locked for redemption operations
     * @dev Used to enforce redemption delay periods after certain operations
     * @custom:access No access restrictions - can be called by anyone
     * @custom:security
     * - Part of the redemption delay mechanism
     * - Used to prevent immediate withdrawals after specific actions
     * - Lock time is managed by RedemptionDelayLib
     */
    function getAccountLockTime(address account_) external view override returns (uint256) {
        return RedemptionDelayLib.getAccountLockTime(account_);
    }

    /**
     * @notice Checks if the contract is currently consuming a scheduled operation
     * @return bytes4 Returns the function selector if consuming a scheduled operation, or bytes4(0) if not
     * @dev Used to track the state of scheduled operation execution
     * @custom:access No access restrictions - can be called by anyone
     * @custom:security
     * - Used internally to prevent reentrancy during scheduled operation execution
     * - Returns this.isConsumingScheduledOp.selector when _customConsumingSchedule is true
     * - Returns bytes4(0) when not consuming a scheduled operation
     */
    function isConsumingScheduledOp() external view override returns (bytes4) {
        return _customConsumingSchedule ? this.isConsumingScheduledOp.selector : bytes4(0);
    }

    function _grantRoleInternal(uint64 roleId_, address account_, uint32 executionDelay_) internal {
        if (executionDelay_ < RoleExecutionTimelockLib.getMinimalExecutionDelayForRole(roleId_)) {
            revert TooShortExecutionDelayForRole(roleId_, executionDelay_);
        }
        _grantRole(roleId_, account_, getRoleGrantDelay(roleId_), executionDelay_);
    }

    function _checkCanCall(address caller_, bytes calldata data_) internal virtual {
        (bool immediate, uint32 delay) = canCall(caller_, address(this), bytes4(data_[0:4]));
        if (!immediate) {
            if (delay > 0) {
                _customConsumingSchedule = true;
                IAccessManager(address(this)).consumeScheduledOp(caller_, data_);
                _customConsumingSchedule = false;
            } else {
                revert AccessManagedUnauthorized(caller_);
            }
        }
    }
}
