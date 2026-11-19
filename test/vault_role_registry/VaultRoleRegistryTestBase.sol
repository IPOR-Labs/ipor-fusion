// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {VaultRoleRegistry} from "../../contracts/vault_role_registry/VaultRoleRegistry.sol";
import {AccountRoles} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {MockVaultRoleRegistryVault} from "./mocks/MockVaultRoleRegistryVault.sol";

/// @title VaultRoleRegistryTestBase
/// @author IPOR Labs
/// @notice Shared fixture for the VaultRoleRegistry unit suites: proxy, two real access managers with a mock vault
/// each, named actors and order-independent snapshot helpers.
abstract contract VaultRoleRegistryTestBase is Test {
    VaultRoleRegistry internal registry;
    VaultRoleRegistry internal implementation;

    IporFusionAccessManager internal managerA;
    IporFusionAccessManager internal managerB;
    address internal vaultA;
    address internal vaultB;

    address internal admin;
    address internal catalogManager;
    address internal remover;
    address internal atomistA;
    address internal atomistB;
    address internal ownerA;
    address internal alphaA;
    address internal stranger;
    address[] internal accounts;

    /// @notice Deploys the registry proxy, two access managers/vaults and grants the actor roles.
    function setUp() public virtual {
        admin = makeAddr("admin");
        catalogManager = makeAddr("catalogManager");
        remover = makeAddr("remover");
        atomistA = makeAddr("atomistA");
        atomistB = makeAddr("atomistB");
        ownerA = makeAddr("ownerA");
        alphaA = makeAddr("alphaA");
        stranger = makeAddr("stranger");
        for (uint256 i; i < 4; ++i) {
            accounts.push(makeAddr(string.concat("account", vm.toString(i))));
        }

        managerA = new IporFusionAccessManager(address(this), 0);
        managerB = new IporFusionAccessManager(address(this), 0);
        managerA.grantRole(Roles.ATOMIST_ROLE, atomistA, 0);
        managerA.grantRole(Roles.OWNER_ROLE, ownerA, 0);
        managerA.grantRole(Roles.ALPHA_ROLE, alphaA, 0);
        managerB.grantRole(Roles.ATOMIST_ROLE, atomistB, 0);
        vaultA = address(new MockVaultRoleRegistryVault(address(managerA)));
        vaultB = address(new MockVaultRoleRegistryVault(address(managerB)));

        implementation = new VaultRoleRegistry();
        registry = _deployRegistry(admin);

        // ROLES_CATALOG_MANAGER_ROLE is not implied by DEFAULT_ADMIN_ROLE, the admin grants it explicitly.
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        vm.prank(admin);
        registry.grantRole(catalogRole, catalogManager);

        // The role id is read before the prank: the getter is an external call and would consume it.
        bytes32 removerRole = registry.VAULT_REMOVER_ROLE();
        vm.prank(admin);
        registry.grantRole(removerRole, remover);
    }

    /// @notice Deploys a fresh ERC1967 proxy over the shared implementation, initialized with `admin_`.
    function _deployRegistry(address admin_) internal returns (VaultRoleRegistry) {
        return
            VaultRoleRegistry(
                address(
                    new ERC1967Proxy(address(implementation), abi.encodeCall(VaultRoleRegistry.initialize, (admin_)))
                )
            );
    }

    /// @notice Grants `roleId_` on `vault_` to `account_` as `atomist_`.
    function _grantAs(address atomist_, address vault_, bytes32 roleId_, address account_) internal {
        vm.prank(atomist_);
        registry.grantVaultRole(vault_, roleId_, account_);
    }

    /// @notice Revokes `roleId_` on `vault_` from `account_` as `atomist_`.
    function _revokeAs(address atomist_, address vault_, bytes32 roleId_, address account_) internal {
        vm.prank(atomist_);
        registry.revokeVaultRole(vault_, roleId_, account_);
    }

    /// @notice Calls `removeVault` on `vault_` as `caller_` and returns the number of accounts left.
    function _removeAs(address caller_, address vault_, uint256 maxAccounts_) internal returns (uint256) {
        vm.prank(caller_);
        return registry.removeVault(vault_, maxAccounts_);
    }

    /// @notice Returns the assignments of a vault, accounts sorted ascending and each account's roleIds sorted.
    function _snapshot(address vault_) internal view returns (AccountRoles[] memory snapshot) {
        snapshot = registry.getVaultAccountsWithRoles(vault_);
        for (uint256 i; i < snapshot.length; ++i) {
            snapshot[i].roleIds = _sortedBytes32(snapshot[i].roleIds);
        }
        // insertion sort by account
        for (uint256 i = 1; i < snapshot.length; ++i) {
            AccountRoles memory key = snapshot[i];
            uint256 j = i;
            while (j > 0 && snapshot[j - 1].account > key.account) {
                snapshot[j] = snapshot[j - 1];
                --j;
            }
            snapshot[j] = key;
        }
    }

    /// @notice Asserts two snapshots from `_snapshot` are identical.
    function _assertSnapshotsEq(AccountRoles[] memory a_, AccountRoles[] memory b_) internal pure {
        assertEq(a_.length, b_.length, "snapshot: accounts count");
        for (uint256 i; i < a_.length; ++i) {
            assertEq(a_[i].account, b_[i].account, "snapshot: account");
            assertEq(a_[i].roleIds.length, b_[i].roleIds.length, "snapshot: roles count");
            for (uint256 j; j < a_[i].roleIds.length; ++j) {
                assertEq(a_[i].roleIds[j], b_[i].roleIds[j], "snapshot: roleId");
            }
        }
    }

    /// @notice Returns registry.getVaults() sorted ascending.
    function _sortedVaults() internal view returns (address[] memory) {
        return _sortedAddresses(registry.getVaults());
    }

    /// @notice Returns registry.getAccountVaults(account_) sorted ascending.
    function _sortedAccountVaults(address account_) internal view returns (address[] memory) {
        return _sortedAddresses(registry.getAccountVaults(account_));
    }

    /// @notice Returns registry.getRoleHolders(vault_, roleId_) sorted ascending.
    function _sortedRoleHolders(address vault_, bytes32 roleId_) internal view returns (address[] memory) {
        return _sortedAddresses(registry.getRoleHolders(vault_, roleId_));
    }

    /// @notice Returns registry.getAccountRoles(vault_, account_) sorted ascending.
    function _sortedAccountRoles(address vault_, address account_) internal view returns (bytes32[] memory) {
        return _sortedBytes32(registry.getAccountRoles(vault_, account_));
    }

    /// @notice Returns a sorted copy of `input_`.
    function _sortedAddresses(address[] memory input_) internal pure returns (address[] memory out) {
        out = new address[](input_.length);
        for (uint256 i; i < input_.length; ++i) {
            out[i] = input_[i];
        }
        for (uint256 i = 1; i < out.length; ++i) {
            address key = out[i];
            uint256 j = i;
            while (j > 0 && out[j - 1] > key) {
                out[j] = out[j - 1];
                --j;
            }
            out[j] = key;
        }
    }

    /// @notice Returns a sorted copy of `input_`.
    function _sortedBytes32(bytes32[] memory input_) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](input_.length);
        for (uint256 i; i < input_.length; ++i) {
            out[i] = input_[i];
        }
        for (uint256 i = 1; i < out.length; ++i) {
            bytes32 key = out[i];
            uint256 j = i;
            while (j > 0 && out[j - 1] > key) {
                out[j] = out[j - 1];
                --j;
            }
            out[j] = key;
        }
    }
}
