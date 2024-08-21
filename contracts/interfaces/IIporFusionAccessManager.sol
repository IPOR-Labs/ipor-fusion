// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

interface IIporFusionAccessManager is IAccessManager {
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

    /// @notice Sets the minimal delay required between deposit / mint and withdrawal / redeem operations.
    /// @param delay The minimal delay in seconds
    function setRedemptionDelay(uint256 delay) external;

    /// @notice Sets the minimal execution delay required for the specified roles.
    /// @param rolesIds The roles for which the minimal execution delay is set
    /// @param delays The minimal execution delays for the specified roles
    function setMinimalExecutionDelaysForRoles(uint64[] calldata rolesIds, uint256[] calldata delays) external;

    function getMinimalExecutionDelayForRole(uint64 roleId) external view returns (uint256);

    function getAccountLockTime(address account) external view returns (uint256);

    function getRedemptionDelay() external view returns (uint256);

    function isConsumingScheduledOp() external view returns (bytes4);
}
