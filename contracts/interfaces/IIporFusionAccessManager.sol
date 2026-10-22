// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title Interface for the IporFusionAccessManager contract that manages access control for the IporFusion contract and its contract satellites
interface IIporFusionAccessManager is IAccessManager {
    /// @notice The redemption delay currently in force - the cooling period between a deposit and the moment
    /// the depositing account may withdraw, redeem or transfer its shares. Set at creation and changeable
    /// afterwards by the OWNER_ROLE via PlasmaVaultGovernance.setRedemptionDelay.
    /// @return The current redemption delay in seconds
    // solhint-disable-next-line func-name-mixedcase
    function REDEMPTION_DELAY_IN_SECONDS() external view returns (uint256);

    /// @notice Sets the vault-wide redemption delay. The new value governs every account immediately -
    /// lowering the delay releases accounts that already deposited, raising it extends their locks,
    /// measured from their own deposits.
    /// @dev Restricted to the TECH_PLASMA_VAULT_ROLE. Governance uses PlasmaVaultGovernance.setRedemptionDelay,
    /// which forwards here. That path is timelocked only when the owner account holds OWNER_ROLE with a non-zero
    /// execution delay - the default initializer grants it with 0, so by default the change is immediate.
    /// Raising the delay is retroactive for existing depositors (see IPlasmaVaultGovernance.setRedemptionDelay).
    /// @param redemptionDelayInSeconds_ The new redemption delay in seconds, reverts with
    /// TooLongRedemptionDelay above MAX_REDEMPTION_DELAY_IN_SECONDS
    function setRedemptionDelay(uint256 redemptionDelayInSeconds_) external;

    /// @notice Check if the caller can call the target with the given selector. Update the account lock time.
    /// @dev canCall cannot be a view function because it updates the account lock time.
    function canCallAndUpdate(
        address caller,
        address target,
        bytes4 selector
    ) external returns (bool immediate, uint32 delay);

    /// @notice Close or open given target to interact with methods with restricted modifiers (emergency pause / unpause).
    /// @dev In most cases when Vault is bootstrapping the ADMIN_ROLE is revoked so a custom method is needed to grant
    /// this ability to the GUARDIAN_ROLE.
    function updateTargetClosed(address target_, bool closed_) external;

    /// @notice Converts the specified vault to a public vault - mint and deposit functions are allowed for everyone.
    /// @dev Notice! Can convert to public but cannot convert back to private.
    /// @param vault_ The address of the vault
    function convertToPublicVault(address vault_) external;

    /// @notice Enables transfer shares, transfer and transferFrom functions are allowed for everyone.
    /// @param vault_ The address of the vault
    function enableTransferShares(address vault_) external;

    /// @notice Sets the minimal execution delay required for the specified roles.
    /// @param rolesIds_ The roles for which the minimal execution delay is set
    /// @param delays_ The minimal execution delays for the specified roles
    function setMinimalExecutionDelaysForRoles(uint64[] calldata rolesIds_, uint256[] calldata delays_) external;

    /// @notice Returns the minimal execution delay required for the specified role.
    /// @param roleId_ The role for which the minimal execution delay is returned
    /// @return The minimal execution delay in seconds
    function getMinimalExecutionDelayForRole(uint64 roleId_) external view returns (uint256);

    /// @notice Returns the effective unlock timestamp for the specified account under the current
    /// redemption delay (last deposit timestamp + REDEMPTION_DELAY_IN_SECONDS). The value moves
    /// immediately, in both directions, whenever the redemption delay is changed.
    /// @param account_ The account for which the account lock time is returned
    /// @dev Exemption-agnostic: also returned for exempt accounts - combine it with isRedemptionDelayExempt.
    /// @return The unlock timestamp, possibly in the past when the lock has expired, 0 when the account never deposited
    function getAccountLockTime(address account_) external view returns (uint256);

    /// @notice Adds or removes a batch of accounts to/from the redemption delay exemptions. An exempt account
    /// behaves as if the vault-wide redemption delay were 0 on withdraw, redeem, transfer and transferFrom.
    /// @dev Restricted to the TECH_PLASMA_VAULT_ROLE. Governance uses PlasmaVaultGovernance.setRedemptionDelayExemption,
    /// which forwards here; that path is timelocked only through the OWNER_ROLE execution delay. Reverts with
    /// Errors.WrongAddress for the whole batch when any account is the zero address. An empty batch is a no-op.
    /// The RedemptionDelayExemptionUpdated(address account, bool exempt) event is emitted for every address, also
    /// when the state did not change. The exemption is evaluated at exit time, so granting and revoking are immediate.
    /// @param accounts_ The accounts to update
    /// @param exempt_ True to exempt the accounts, false to remove the exemption
    function setRedemptionDelayExemption(address[] calldata accounts_, bool exempt_) external;

    /// @notice Checks whether an account is exempt from the redemption delay.
    /// @param account_ The account to check
    /// @return True when the account is exempt
    function isRedemptionDelayExempt(address account_) external view returns (bool);

    /// @notice Returns all accounts exempt from the redemption delay.
    /// @dev The order is not stable across removals.
    /// @return The full list of exempt accounts
    function getRedemptionDelayExemptions() external view returns (address[] memory);

    /// @notice Returns the number of accounts exempt from the redemption delay.
    /// @return The number of exempt accounts
    function getRedemptionDelayExemptionsCount() external view returns (uint256);

    /// @notice Returns a page of accounts exempt from the redemption delay.
    /// @dev Returns an empty array when offset_ >= count, otherwise min(limit_, count - offset_) accounts.
    /// The order is not stable across removals, so read all pages in one block.
    /// @param offset_ Index of the first account to return
    /// @param limit_ Maximum number of accounts to return
    /// @return The requested page of exempt accounts
    function getRedemptionDelayExemptionsAt(uint256 offset_, uint256 limit_) external view returns (address[] memory);

    /// @notice Returns the function selector for the scheduled operation that is currently being consumed.
    /// @return The function selector
    function isConsumingScheduledOp() external view returns (bytes4);
}
