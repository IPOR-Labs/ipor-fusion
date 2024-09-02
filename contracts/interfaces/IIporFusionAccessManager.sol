// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title Interface for the IporFusionAccessManager contract that manages access control for the IporFusion contract and its contract satellites
interface IIporFusionAccessManager is IAccessManager {
    /// @notice The minimal delay required for the timelocked functions, value is set in the constructor, cannot be changed
    /// @return The minimal delay in seconds
    // solhint-disable-next-line func-name-mixedcase
    function REDEMPTION_DELAY_IN_SECONDS() external view returns (uint256);

    /// @notice Check if the caller can call the target with the given selector. Update the account lock time.
    /// @dev canCall cannot be a view function because it updates the account lock time.
    function canCallAndUpdate(
        address caller,
        address target,
        bytes4 selector
    ) external returns (bool immediate, uint32 delay);

    /// @notice Close or open given target to interact with methods with restricted modifiers.
    /// @dev In most cases when Vault is bootstrapping the ADMIN_ROLE  is revoked so custom method is needed to grant roles for a GUARDIAN_ROLE.
    function updateTargetClosed(address target, bool closed) external;

    /// @notice Converts the specified vault to a public vault - mint and deposit functions are allowed for everyone.
    /// @dev Notice! Can convert to public but cannot convert back to private.
    /// @param vault The address of the vault
    function convertToPublicVault(address vault) external;

    /// @notice Enables transfer shares, transfer and transferFrom functions are allowed for everyone.
    /// @param vault The address of the vault
    function enableTransferShares(address vault) external;

    /// @notice Sets the minimal execution delay required for the specified roles.
    /// @param rolesIds The roles for which the minimal execution delay is set
    /// @param delays The minimal execution delays for the specified roles
    function setMinimalExecutionDelaysForRoles(uint64[] calldata rolesIds, uint256[] calldata delays) external;

    /// @notice Returns the minimal execution delay required for the specified role.
    /// @param roleId The role for which the minimal execution delay is returned
    /// @return The minimal execution delay in seconds
    function getMinimalExecutionDelayForRole(uint64 roleId) external view returns (uint256);

    /// @notice Returns the account lock time for the specified account.
    /// @param account The account for which the account lock time is returned
    /// @return The account lock time in seconds
    function getAccountLockTime(address account) external view returns (uint256);

    /// @notice Returns the function selector for the scheduled operation that is currently being consumed.
    /// @return The function selector
    function isConsumingScheduledOp() external view returns (bytes4);
}
