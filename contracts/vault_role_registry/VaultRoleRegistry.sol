// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Errors} from "../libraries/errors/Errors.sol";
import {Roles} from "../libraries/Roles.sol";
import {IVaultRoleRegistry, VaultRoleDefinition, AccountRoles} from "./IVaultRoleRegistry.sol";
import {VaultRoleRegistryAccessControl} from "./VaultRoleRegistryAccessControl.sol";
import {VaultRoleRegistryStorageLib} from "./VaultRoleRegistryStorageLib.sol";

/**
 * @title VaultRoleRegistry
 * @author IPOR Labs
 * @notice Registry in which the atomist of a Plasma Vault assigns informational roles (Risk Manager, Risk Monitor,
 * Brand Manager and any role added later) to accounts, per vault. The registry grants no on-chain permissions.
 *
 * @dev Access Control:
 * @dev This contract uses role-based access control (OpenZeppelin AccessControl), NOT Ownable.
 * @dev - DEFAULT_ADMIN_ROLE: grants/revokes other roles (including ROLES_CATALOG_MANAGER_ROLE) and authorizes upgrades
 * @dev - ROLES_CATALOG_MANAGER_ROLE: adds roles to the catalogue, changes labels, (de)activates roles. It is separate
 * from DEFAULT_ADMIN_ROLE; the admin has to grant it to itself if needed.
 * @dev - VAULT_REMOVER_ROLE: clears the assignments of a vault with `removeVault`, without asking the vault. Granted
 * by DEFAULT_ADMIN_ROLE, not granted in `initialize`.
 * @dev - Atomist of the vault (ATOMIST_ROLE in the access manager of the vault): grants and revokes role assignments
 * for that vault. The execution delay of the role in the access manager is ignored; a grant delay works as usual
 * (the account is not a member until the grant becomes effective).
 */
contract VaultRoleRegistry is IVaultRoleRegistry, VaultRoleRegistryAccessControl, UUPSUpgradeable {
    /// @notice Maximum length of a role label in bytes
    uint256 public constant MAX_VAULT_ROLE_LABEL_LENGTH = 64;

    /// @notice Identifier of the Risk Manager role
    /// @dev bytes32 - 0x31b1eef659b3a1eff8141d282b94bb64fd3fc317f01cc6ab4b25ccb3e718ce8b
    bytes32 public constant VAULT_ROLE_RISK_MANAGER = keccak256("RISK_MANAGER");

    /// @notice Identifier of the Risk Monitor role
    /// @dev bytes32 - 0x39a3bf5849fcef48756e74158f4deb6e1ffdc9c8bd6eb55d2ab95708941ff1bf
    bytes32 public constant VAULT_ROLE_RISK_MONITOR = keccak256("RISK_MONITOR");

    /// @notice Identifier of the Brand Manager role
    /// @dev bytes32 - 0x2d8e650da9bd8c373ab2450d770f2ed39549bfc28d3630025cecc51511bcd374
    bytes32 public constant VAULT_ROLE_BRAND_MANAGER = keccak256("BRAND_MANAGER");

    /// @notice Initializes the registry and seeds the catalogue with the three starting roles
    /// @param initialAdmin_ The account granted DEFAULT_ADMIN_ROLE; must not be zero. ROLES_CATALOG_MANAGER_ROLE is
    /// not granted, the admin has to grant it explicitly. Should be a multi-sig wallet.
    function initialize(address initialAdmin_) external initializer {
        if (initialAdmin_ == address(0)) {
            revert Errors.WrongAddress();
        }
        __VaultRoleRegistryAccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);

        _addVaultRole(VAULT_ROLE_RISK_MANAGER, "Risk Manager");
        _addVaultRole(VAULT_ROLE_RISK_MONITOR, "Risk Monitor");
        _addVaultRole(VAULT_ROLE_BRAND_MANAGER, "Brand Manager");
    }

    // ---------------------------------------------------------------- catalogue writes

    /// @inheritdoc IVaultRoleRegistry
    function addVaultRole(bytes32 roleId_, string calldata label_) external onlyRole(ROLES_CATALOG_MANAGER_ROLE) {
        _addVaultRole(roleId_, label_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function updateVaultRoleLabel(
        bytes32 roleId_,
        string calldata label_
    ) external onlyRole(ROLES_CATALOG_MANAGER_ROLE) {
        _checkLabel(label_);
        VaultRoleRegistryStorageLib.setVaultRoleLabel(roleId_, label_);
        emit VaultRoleLabelUpdated(roleId_, label_, msg.sender);
    }

    /// @inheritdoc IVaultRoleRegistry
    function setVaultRoleActive(bytes32 roleId_, bool active_) external onlyRole(ROLES_CATALOG_MANAGER_ROLE) {
        VaultRoleRegistryStorageLib.setVaultRoleActive(roleId_, active_);
        emit VaultRoleActiveUpdated(roleId_, active_, msg.sender);
    }

    // ---------------------------------------------------------------- assignment writes

    /// @inheritdoc IVaultRoleRegistry
    function grantVaultRole(address vault_, bytes32 roleId_, address account_) external {
        _requireNonZero(vault_);
        _requireNonZero(account_);
        _checkVaultAtomist(vault_);
        _grantVaultRole(vault_, roleId_, account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function revokeVaultRole(address vault_, bytes32 roleId_, address account_) external {
        _requireNonZero(vault_);
        _requireNonZero(account_);
        _checkVaultAtomist(vault_);
        _revokeVaultRole(vault_, roleId_, account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function grantVaultRoles(address vault_, bytes32[] calldata roleIds_, address[] calldata accounts_) external {
        uint256 length = roleIds_.length;
        if (length == 0 || length != accounts_.length) {
            revert Errors.WrongArrayLength();
        }
        _requireNonZero(vault_);
        _checkVaultAtomist(vault_);
        for (uint256 i; i < length; ++i) {
            _requireNonZero(accounts_[i]);
            _grantVaultRole(vault_, roleIds_[i], accounts_[i]);
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function revokeVaultRoles(address vault_, bytes32[] calldata roleIds_, address[] calldata accounts_) external {
        uint256 length = roleIds_.length;
        if (length == 0 || length != accounts_.length) {
            revert Errors.WrongArrayLength();
        }
        _requireNonZero(vault_);
        _checkVaultAtomist(vault_);
        for (uint256 i; i < length; ++i) {
            _requireNonZero(accounts_[i]);
            _revokeVaultRole(vault_, roleIds_[i], accounts_[i]);
        }
    }

    // ---------------------------------------------------------------- vault removal

    /// @inheritdoc IVaultRoleRegistry
    function removeVault(
        address vault_,
        uint256 maxAccounts_
    ) external onlyRole(VAULT_REMOVER_ROLE) returns (uint256 remaining) {
        _requireNonZero(vault_);
        if (maxAccounts_ == 0) {
            revert Errors.WrongValue();
        }
        uint256 count = VaultRoleRegistryStorageLib.getVaultAccountsCount(vault_);
        if (count == 0) {
            revert VaultNotRegistered(vault_);
        }
        uint256 toRemove = maxAccounts_ < count ? maxAccounts_ : count;
        for (uint256 i; i < toRemove; ++i) {
            // Removing the last element of the set does not reorder the others, so `count - 1 - i` is always the
            // current last account.
            address account = VaultRoleRegistryStorageLib.getVaultAccountAt(vault_, count - 1 - i);
            bytes32[] memory roleIds = VaultRoleRegistryStorageLib.getAccountRoles(vault_, account);
            for (uint256 j; j < roleIds.length; ++j) {
                bool vaultRemoved = VaultRoleRegistryStorageLib.revoke(vault_, roleIds[j], account);
                emit VaultRoleRevoked(vault_, roleIds[j], account, msg.sender);
                if (vaultRemoved) {
                    emit VaultRemoved(vault_, msg.sender);
                }
            }
        }
        remaining = count - toRemove;
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IVaultRoleRegistry
    function getVaultRoles() external view returns (VaultRoleDefinition[] memory definitions) {
        bytes32[] memory roleIds = VaultRoleRegistryStorageLib.getVaultRoleIds();
        uint256 length = roleIds.length;
        definitions = new VaultRoleDefinition[](length);
        for (uint256 i; i < length; ++i) {
            definitions[i] = _definition(roleIds[i]);
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaultRole(bytes32 roleId_) external view returns (VaultRoleDefinition memory) {
        if (!VaultRoleRegistryStorageLib.isVaultRoleDefined(roleId_)) {
            revert UnknownVaultRole(roleId_);
        }
        return _definition(roleId_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function isVaultRoleDefined(bytes32 roleId_) external view returns (bool) {
        return VaultRoleRegistryStorageLib.isVaultRoleDefined(roleId_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaults() external view returns (address[] memory) {
        return VaultRoleRegistryStorageLib.getVaults();
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaultsCount() external view returns (uint256) {
        return VaultRoleRegistryStorageLib.getVaultsCount();
    }

    /// @inheritdoc IVaultRoleRegistry
    /// @dev Order is not stable (swap-and-pop) and `offset_` is not a cursor between blocks: read all pages at the
    /// same block. `offset_ >= count` or `limit_ == 0` returns an empty array, otherwise `min(limit_, count - offset_)`
    /// items.
    function getVaultsPaginated(uint256 offset_, uint256 limit_) external view returns (address[] memory page) {
        uint256 size = _pageSize(VaultRoleRegistryStorageLib.getVaultsCount(), offset_, limit_);
        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = VaultRoleRegistryStorageLib.getVaultAt(offset_ + i);
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaultAccountsWithRoles(address vault_) external view returns (AccountRoles[] memory result) {
        uint256 count = VaultRoleRegistryStorageLib.getVaultAccountsCount(vault_);
        result = new AccountRoles[](count);
        for (uint256 i; i < count; ++i) {
            address account = VaultRoleRegistryStorageLib.getVaultAccountAt(vault_, i);
            result[i] = AccountRoles({
                account: account,
                roleIds: VaultRoleRegistryStorageLib.getAccountRoles(vault_, account)
            });
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaultAccountsCount(address vault_) external view returns (uint256) {
        return VaultRoleRegistryStorageLib.getVaultAccountsCount(vault_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getVaultAccountsWithRolesPaginated(
        address vault_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (AccountRoles[] memory page) {
        uint256 size = _pageSize(VaultRoleRegistryStorageLib.getVaultAccountsCount(vault_), offset_, limit_);
        page = new AccountRoles[](size);
        for (uint256 i; i < size; ++i) {
            address account = VaultRoleRegistryStorageLib.getVaultAccountAt(vault_, offset_ + i);
            page[i] = AccountRoles({
                account: account,
                roleIds: VaultRoleRegistryStorageLib.getAccountRoles(vault_, account)
            });
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function getAccountRoles(address vault_, address account_) external view returns (bytes32[] memory) {
        return VaultRoleRegistryStorageLib.getAccountRoles(vault_, account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getRoleHolders(address vault_, bytes32 roleId_) external view returns (address[] memory) {
        return VaultRoleRegistryStorageLib.getRoleHolders(vault_, roleId_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getRoleHoldersCount(address vault_, bytes32 roleId_) external view returns (uint256) {
        return VaultRoleRegistryStorageLib.getRoleHoldersCount(vault_, roleId_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getRoleHoldersPaginated(
        address vault_,
        bytes32 roleId_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory page) {
        uint256 size = _pageSize(VaultRoleRegistryStorageLib.getRoleHoldersCount(vault_, roleId_), offset_, limit_);
        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = VaultRoleRegistryStorageLib.getRoleHolderAt(vault_, roleId_, offset_ + i);
        }
    }

    /// @inheritdoc IVaultRoleRegistry
    function hasVaultRole(address vault_, bytes32 roleId_, address account_) external view returns (bool) {
        return VaultRoleRegistryStorageLib.hasVaultRole(vault_, roleId_, account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getAccountVaults(address account_) external view returns (address[] memory) {
        return VaultRoleRegistryStorageLib.getAccountVaults(account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    function getAccountVaultsCount(address account_) external view returns (uint256) {
        return VaultRoleRegistryStorageLib.getAccountVaultsCount(account_);
    }

    /// @inheritdoc IVaultRoleRegistry
    /// @dev Order is not stable (swap-and-pop) and `offset_` is not a cursor between blocks: read all pages at the
    /// same block. `offset_ >= count` or `limit_ == 0` returns an empty array, otherwise `min(limit_, count - offset_)`
    /// items.
    function getAccountVaultsPaginated(
        address account_,
        uint256 offset_,
        uint256 limit_
    ) external view returns (address[] memory page) {
        uint256 size = _pageSize(VaultRoleRegistryStorageLib.getAccountVaultsCount(account_), offset_, limit_);
        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = VaultRoleRegistryStorageLib.getAccountVaultAt(account_, offset_ + i);
        }
    }

    // ---------------------------------------------------------------- internal

    function _addVaultRole(bytes32 roleId_, string memory label_) internal {
        if (roleId_ == bytes32(0)) {
            revert InvalidVaultRoleId();
        }
        _checkLabel(label_);
        VaultRoleRegistryStorageLib.addVaultRole(roleId_, label_);
        emit VaultRoleAdded(roleId_, label_, msg.sender);
    }

    function _grantVaultRole(address vault_, bytes32 roleId_, address account_) internal {
        if (!VaultRoleRegistryStorageLib.isVaultRoleDefined(roleId_)) {
            revert UnknownVaultRole(roleId_);
        }
        if (!VaultRoleRegistryStorageLib.isVaultRoleActive(roleId_)) {
            revert VaultRoleInactive(roleId_);
        }
        bool vaultAdded = VaultRoleRegistryStorageLib.grant(vault_, roleId_, account_);
        emit VaultRoleGranted(vault_, roleId_, account_, msg.sender);
        if (vaultAdded) {
            emit VaultAdded(vault_, msg.sender);
        }
    }

    function _revokeVaultRole(address vault_, bytes32 roleId_, address account_) internal {
        if (!VaultRoleRegistryStorageLib.isVaultRoleDefined(roleId_)) {
            revert UnknownVaultRole(roleId_);
        }
        bool vaultRemoved = VaultRoleRegistryStorageLib.revoke(vault_, roleId_, account_);
        emit VaultRoleRevoked(vault_, roleId_, account_, msg.sender);
        if (vaultRemoved) {
            emit VaultRemoved(vault_, msg.sender);
        }
    }

    /// @dev Reverts unless `msg.sender` is a member of ATOMIST_ROLE in the access manager of the vault
    function _checkVaultAtomist(address vault_) internal view {
        address accessManager = IAccessManaged(vault_).authority();
        if (accessManager == address(0)) {
            revert NoAccessManager(vault_);
        }
        (bool isMember, ) = IAccessManager(accessManager).hasRole(Roles.ATOMIST_ROLE, msg.sender);
        if (!isMember) {
            revert CallerNotVaultAtomist(vault_, msg.sender);
        }
    }

    function _checkLabel(string memory label_) internal pure {
        uint256 length = bytes(label_).length;
        if (length == 0 || length > MAX_VAULT_ROLE_LABEL_LENGTH) {
            revert InvalidVaultRoleLabel();
        }
    }

    function _requireNonZero(address account_) internal pure {
        if (account_ == address(0)) {
            revert Errors.WrongAddress();
        }
    }

    function _definition(bytes32 roleId_) internal view returns (VaultRoleDefinition memory) {
        VaultRoleRegistryStorageLib.VaultRoleData memory data = VaultRoleRegistryStorageLib.getVaultRoleData(roleId_);
        return VaultRoleDefinition({roleId: roleId_, label: data.label, active: data.active});
    }

    function _pageSize(uint256 count_, uint256 offset_, uint256 limit_) internal pure returns (uint256) {
        if (offset_ >= count_ || limit_ == 0) {
            return 0;
        }
        uint256 remaining = count_ - offset_;
        return limit_ < remaining ? limit_ : remaining;
    }

    /// @dev Required by the OZ UUPS module
    /// @dev Only addresses with DEFAULT_ADMIN_ROLE can authorize contract upgrades
    /// @param newImplementation Address of the new implementation
    //solhint-disable-next-line
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
