// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IIporFusionAccessManager} from "../../interfaces/IIporFusionAccessManager.sol";
import {Errors} from "../../libraries/errors/Errors.sol";

/**
 * @title PlasmaVaultPauser
 * @author IPOR Labs
 * @notice Emergency pause contract for IPOR Fusion Plasma Vaults. Allows whitelisted accounts to pause
 * a given Plasma Vault by closing it on its IporFusionAccessManager (authority).
 * @dev The contract is intentionally minimal and NOT upgradeable:
 * - The only action it can ever perform on a vault is `closeTarget(vault)` on the vault's
 *   IporFusionAccessManager - a one-way function mapped to PAUSER_ROLE. The selector is hard-coded and the
 *   function itself can only close, so this contract can pause a vault but can never reopen it, nor call any
 *   other restricted function (it never calls `updateTargetClosed`).
 * - Reopening a paused vault must be performed directly on the IporFusionAccessManager by an account
 *   with the GUARDIAN_ROLE (updateTargetClosed).
 *
 * Access control:
 * - Ownership follows the two-step pattern (Ownable2Step). The initial owner is set in the constructor
 *   and must be a non-zero address (a zero address reverts - no silent fallback to the deployer).
 * - `renounceOwnership` is disabled to prevent accidentally leaving the whitelist unmanageable.
 * - The owner manages a per-vault whitelist: an account is whitelisted for a specific vault and can
 *   pause only that vault.
 * - Whitelist entries are ONE-SHOT: a successful `pause` consumes the caller's entry for that vault.
 *   An emergency pause is by nature a single action, and a compromised or misbehaving key must not be
 *   able to re-close a vault every time a guardian reopens it (pause / reopen ping-pong) while the
 *   owner - possibly a timelocked multisig - is still removing it from the whitelist. To pause the same
 *   vault again the owner has to whitelist the account again.
 *
 * Trust model:
 * - The owner of this contract is a trust anchor OUTSIDE the Fusion role system (Ownable2Step, not
 *   AccessManaged). One deployment serves many vaults: every vault that grants PAUSER_ROLE to this
 *   contract delegates to the pauser's owner the decision of WHO may pause that vault. The owner is
 *   therefore expected to be a multisig, and each vault's governance opts in explicitly by granting the
 *   role (and can opt out at any time by revoking it).
 * - The whitelist is enumerable in both directions: accounts whitelisted for a given vault and vaults
 *   assigned to a given account can be listed on-chain without external indexing. Count and paginated
 *   getters are provided for sets too large to be read in a single call.
 * - Global registries of all configured vaults and all configured accounts are enumerable as well,
 *   an entry stays listed while it has at least one active whitelist assignment.
 *
 * Function permissions:
 * - pause / pauseMany: Restricted to accounts whitelisted for the given vault(s), one-shot per vault
 * - addToWhitelist: Restricted to the owner
 * - removeFromWhitelist: Restricted to the owner
 *
 * Integration requirements:
 * - This contract must be granted the PAUSER_ROLE on the IporFusionAccessManager of every vault it is
 *   expected to pause, with execution delay set to 0. PAUSER_ROLE is mapped only to the one-way `closeTarget`
 *   on vaults initialized with IporFusionAccessManagerInitializerLibV1 (from IL-7725): it can pause but can
 *   neither unpause nor cancel scheduled operations. Do NOT grant GUARDIAN_ROLE to this contract - that role
 *   can reopen vaults and cancel operations, which this contract never needs (defense in depth, even though it
 *   cannot call them).
 * - Legacy vaults whose access manager has no `closeTarget` (non-upgradeable clones deployed before IL-7725)
 *   are NOT supported: `pause` reverts on the unknown selector. Those vaults are paused by their guardians
 *   directly through `updateTargetClosed`.
 * - Vault addresses added to the whitelist are trusted IPOR Fusion Plasma Vaults, curated by the owner.
 *
 * Security features:
 * - Per-vault whitelist prevents a compromised pauser account from pausing unrelated vaults
 * - One-shot whitelist entries prevent pause / reopen loops by a compromised account
 * - Post-condition check verifies the vault is effectively closed on the access manager
 * - One-way action (pause only) limits the blast radius of a compromised pauser account
 */
contract PlasmaVaultPauser is Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Emitted when an account is added to the whitelist of a given vault
    /// @param vault The vault for which the account is whitelisted
    /// @param account The account allowed to pause the vault
    event AddressAddedToWhitelist(address vault, address account);

    /// @notice Emitted when an account is removed from the whitelist of a given vault, either by the owner
    /// or because the account consumed its one-shot entry by pausing the vault
    /// @param vault The vault for which the account is removed
    /// @param account The account no longer allowed to pause the vault
    event AddressRemovedFromWhitelist(address vault, address account);

    /// @notice Emitted when a vault is paused (closed on its access manager)
    /// @param vault The paused vault
    /// @param accessManager The IporFusionAccessManager on which the vault was closed
    /// @param account The whitelisted account that triggered the pause
    event VaultPaused(address vault, address accessManager, address account);

    /// @notice Thrown when the caller is not whitelisted for the given vault
    error AccountNotWhitelisted(address vault, address account);
    /// @notice Thrown when the vault reports a zero address authority
    error InvalidAuthority(address vault);
    /// @notice Thrown when the access manager did not close the vault despite a successful call
    error VaultPauseFailed(address vault);
    /// @notice Thrown when attempting to renounce ownership, which is disabled
    error RenounceOwnershipDisabled();

    /// @notice Accounts allowed to pause a given vault, managed by the owner
    /// @dev vault => set of whitelisted accounts, kept in sync with _whitelistedVaults
    mapping(address vault => EnumerableSet.AddressSet accounts) private _whitelistedAccounts;

    /// @notice Vaults a given account is allowed to pause, managed by the owner
    /// @dev account => set of vaults, kept in sync with _whitelistedAccounts
    mapping(address account => EnumerableSet.AddressSet vaults) private _whitelistedVaults;

    /// @notice All vaults that currently have at least one whitelisted account
    EnumerableSet.AddressSet private _allVaults;

    /// @notice All accounts that are currently whitelisted for at least one vault
    EnumerableSet.AddressSet private _allAccounts;

    /// @notice Sets the initial owner of the contract
    /// @param initialOwner_ The initial owner address, expected to be a multisig (see the trust model above)
    /// @dev The zero address reverts with Ownable.OwnableInvalidOwner - a typo in a deployment script must not silently
    /// hand ownership to the deployer key. Ownership can be transferred later only via the two-step process
    constructor(address initialOwner_) Ownable(initialOwner_) {
        /// @dev Ownable already rejects address(0); no fallback to msg.sender on purpose
    }

    /**
     * @notice Pauses the given Plasma Vault by closing it on its IporFusionAccessManager
     * @param vaultAddress_ The address of the Plasma Vault to pause
     * @dev Reads the vault's authority (IporFusionAccessManager) and calls `closeTarget(vault)` - the only
     * access manager function this contract ever invokes. Verifies the vault is effectively closed afterwards.
     * This contract cannot reopen the vault; legacy access managers without `closeTarget` revert.
     * The caller's whitelist entry for this vault is consumed (one-shot) before the external call and an
     * AddressRemovedFromWhitelist event is emitted; when the access manager refuses the call (e.g. this contract
     * lacks PAUSER_ROLE) the whole transaction reverts and the entry is kept.
     * @custom:access Restricted to accounts whitelisted for the given vault
     */
    function pause(address vaultAddress_) external {
        _pause(vaultAddress_);
    }

    /**
     * @notice Pauses several Plasma Vaults in one transaction, e.g. when a shared oracle misbehaves
     * @param vaultAddresses_ The addresses of the Plasma Vaults to pause
     * @dev All-or-nothing: the caller must be whitelisted for every vault in the list and every pause must
     * succeed, otherwise the whole transaction reverts. Each entry is consumed independently (one-shot per vault).
     * @custom:access Restricted to accounts whitelisted for every given vault
     */
    function pauseMany(address[] calldata vaultAddresses_) external {
        uint256 length = vaultAddresses_.length;
        for (uint256 i; i < length; ++i) {
            _pause(vaultAddresses_[i]);
        }
    }

    /**
     * @notice Adds an account to the whitelist of a given vault
     * @param vaultAddress_ The vault for which the account is allowed to call `pause`
     * @param account_ The account to whitelist
     * @dev Idempotent - adding an already whitelisted account does not emit an event
     * @custom:access Restricted to the owner
     */
    function addToWhitelist(address vaultAddress_, address account_) external onlyOwner {
        if (vaultAddress_ == address(0) || account_ == address(0)) {
            revert Errors.WrongAddress();
        }

        if (!_whitelistedAccounts[vaultAddress_].add(account_)) {
            return;
        }

        _whitelistedVaults[account_].add(vaultAddress_);
        _allVaults.add(vaultAddress_);
        _allAccounts.add(account_);

        emit AddressAddedToWhitelist(vaultAddress_, account_);
    }

    /**
     * @notice Removes an account from the whitelist of a given vault
     * @param vaultAddress_ The vault for which the account is no longer allowed to call `pause`
     * @param account_ The account to remove
     * @dev Idempotent - removing a not whitelisted account does not emit an event.
     * The vault and the account are removed from the global registries together with their last assignment.
     * @custom:access Restricted to the owner
     */
    function removeFromWhitelist(address vaultAddress_, address account_) external onlyOwner {
        _removeFromWhitelist(vaultAddress_, account_);
    }

    /**
     * @notice Checks whether an account is whitelisted to pause a given vault
     * @param vaultAddress_ The vault address
     * @param account_ The account address
     * @return True when the account is allowed to call `pause` for the given vault
     */
    function isWhitelisted(address vaultAddress_, address account_) external view returns (bool) {
        return _whitelistedAccounts[vaultAddress_].contains(account_);
    }

    /**
     * @notice Returns all accounts whitelisted to pause a given vault
     * @param vaultAddress_ The vault address
     * @return Array of whitelisted accounts, order is not guaranteed
     * @dev Copies the whole set to memory, intended for off-chain reads of small sets.
     * For large sets use {getWhitelistedAccountsCount} with {getWhitelistedAccountsPage}.
     */
    function getWhitelistedAccounts(address vaultAddress_) external view returns (address[] memory) {
        return _whitelistedAccounts[vaultAddress_].values();
    }

    /**
     * @notice Returns the number of accounts whitelisted to pause a given vault
     * @param vaultAddress_ The vault address
     * @return Number of whitelisted accounts
     */
    function getWhitelistedAccountsCount(address vaultAddress_) external view returns (uint256) {
        return _whitelistedAccounts[vaultAddress_].length();
    }

    /**
     * @notice Returns a page of accounts whitelisted to pause a given vault
     * @param vaultAddress_ The vault address
     * @param offset_ Zero-based index of the first account to return
     * @param limit_ Maximum number of accounts to return
     * @return Array of at most `limit_` accounts starting at `offset_`, empty when `offset_` is out of range.
     * Order is not guaranteed but stable between calls as long as the whitelist is not modified.
     */
    function getWhitelistedAccountsPage(
        address vaultAddress_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory) {
        return _paginate(_whitelistedAccounts[vaultAddress_], offset_, limit_);
    }

    /**
     * @notice Returns all vaults a given account is whitelisted to pause
     * @param account_ The account address
     * @return Array of vaults, order is not guaranteed
     * @dev Copies the whole set to memory, intended for off-chain reads of small sets.
     * For large sets use {getWhitelistedVaultsCount} with {getWhitelistedVaultsPage}.
     */
    function getWhitelistedVaults(address account_) external view returns (address[] memory) {
        return _whitelistedVaults[account_].values();
    }

    /**
     * @notice Returns the number of vaults a given account is whitelisted to pause
     * @param account_ The account address
     * @return Number of vaults
     */
    function getWhitelistedVaultsCount(address account_) external view returns (uint256) {
        return _whitelistedVaults[account_].length();
    }

    /**
     * @notice Returns a page of vaults a given account is whitelisted to pause
     * @param account_ The account address
     * @param offset_ Zero-based index of the first vault to return
     * @param limit_ Maximum number of vaults to return
     * @return Array of at most `limit_` vaults starting at `offset_`, empty when `offset_` is out of range.
     * Order is not guaranteed but stable between calls as long as the whitelist is not modified.
     */
    function getWhitelistedVaultsPage(
        address account_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory) {
        return _paginate(_whitelistedVaults[account_], offset_, limit_);
    }

    /**
     * @notice Returns all vaults that currently have at least one whitelisted account
     * @return Array of vaults, order is not guaranteed
     * @dev Copies the whole set to memory, intended for off-chain reads of small sets.
     * For large sets use {getVaultsCount} with {getVaultsPage}.
     */
    function getVaults() external view returns (address[] memory) {
        return _allVaults.values();
    }

    /**
     * @notice Returns the number of vaults that currently have at least one whitelisted account
     * @return Number of configured vaults
     */
    function getVaultsCount() external view returns (uint256) {
        return _allVaults.length();
    }

    /**
     * @notice Returns a page of vaults that currently have at least one whitelisted account
     * @param offset_ Zero-based index of the first vault to return
     * @param limit_ Maximum number of vaults to return
     * @return Array of at most `limit_` vaults starting at `offset_`, empty when `offset_` is out of range.
     * Order is not guaranteed but stable between calls as long as the whitelist is not modified.
     */
    function getVaultsPage(uint256 offset_, uint256 limit_) external view returns (address[] memory) {
        return _paginate(_allVaults, offset_, limit_);
    }

    /**
     * @notice Returns all accounts that are currently whitelisted for at least one vault
     * @return Array of accounts, order is not guaranteed
     * @dev Copies the whole set to memory, intended for off-chain reads of small sets.
     * For large sets use {getAccountsCount} with {getAccountsPage}.
     */
    function getAccounts() external view returns (address[] memory) {
        return _allAccounts.values();
    }

    /**
     * @notice Returns the number of accounts that are currently whitelisted for at least one vault
     * @return Number of configured accounts
     */
    function getAccountsCount() external view returns (uint256) {
        return _allAccounts.length();
    }

    /**
     * @notice Returns a page of accounts that are currently whitelisted for at least one vault
     * @param offset_ Zero-based index of the first account to return
     * @param limit_ Maximum number of accounts to return
     * @return Array of at most `limit_` accounts starting at `offset_`, empty when `offset_` is out of range.
     * Order is not guaranteed but stable between calls as long as the whitelist is not modified.
     */
    function getAccountsPage(uint256 offset_, uint256 limit_) external view returns (address[] memory) {
        return _paginate(_allAccounts, offset_, limit_);
    }

    /**
     * @notice Renouncing ownership is disabled
     * @dev Prevents accidentally leaving the whitelist unmanageable. Ownership can only be moved
     * via the two-step transfer process. Reverts with RenounceOwnershipDisabled for every caller - no
     * `onlyOwner` so a non-owner gets the real reason instead of a misleading OwnableUnauthorizedAccount.
     */
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    /// @dev Consumes the caller's one-shot whitelist entry, closes the vault on its access manager and verifies it
    function _pause(address vaultAddress_) private {
        if (!_whitelistedAccounts[vaultAddress_].contains(msg.sender)) {
            revert AccountNotWhitelisted(vaultAddress_, msg.sender);
        }

        /// @dev One-shot: consumed before the external call (checks-effects-interactions), reverted together
        /// with the whole transaction when the access manager refuses the pause
        _removeFromWhitelist(vaultAddress_, msg.sender);

        address accessManager = IAccessManaged(vaultAddress_).authority();

        if (accessManager == address(0)) {
            revert InvalidAuthority(vaultAddress_);
        }

        /// @dev One-way close (PAUSER_ROLE) - the only call this contract makes on an access manager
        IIporFusionAccessManager(accessManager).closeTarget(vaultAddress_);

        if (!IIporFusionAccessManager(accessManager).isTargetClosed(vaultAddress_)) {
            revert VaultPauseFailed(vaultAddress_);
        }

        emit VaultPaused(vaultAddress_, accessManager, msg.sender);
    }

    /// @dev Removes the account from the vault's whitelist keeping both sides and the global registries in sync.
    /// Idempotent - no event when the account was not whitelisted
    function _removeFromWhitelist(address vaultAddress_, address account_) private {
        if (!_whitelistedAccounts[vaultAddress_].remove(account_)) {
            return;
        }

        _whitelistedVaults[account_].remove(vaultAddress_);

        if (_whitelistedAccounts[vaultAddress_].length() == 0) {
            _allVaults.remove(vaultAddress_);
        }

        if (_whitelistedVaults[account_].length() == 0) {
            _allAccounts.remove(account_);
        }

        emit AddressRemovedFromWhitelist(vaultAddress_, account_);
    }

    /// @dev Returns at most `limit_` elements of the set starting at `offset_`
    function _paginate(
        EnumerableSet.AddressSet storage set_,
        uint256 offset_,
        uint256 limit_
    ) private view returns (address[] memory page) {
        uint256 total = set_.length();

        if (offset_ >= total) {
            return new address[](0);
        }

        uint256 size = total - offset_;
        if (size > limit_) {
            size = limit_;
        }

        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = set_.at(offset_ + i);
        }
    }
}
