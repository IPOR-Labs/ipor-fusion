// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {VaultRoleRegistry} from "../../contracts/vault_role_registry/VaultRoleRegistry.sol";
import {
    IVaultRoleRegistry,
    VaultRoleDefinition,
    AccountRoles
} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {VaultRoleRegistryTestBase} from "./VaultRoleRegistryTestBase.sol";

/// @title VaultRoleRegistryManagementTest
/// @notice Initialization, seeded roles, admin and catalogue access control, catalogue validation, label change
/// preserving assignments and upgrade of the VaultRoleRegistry.
contract VaultRoleRegistryManagementTest is VaultRoleRegistryTestBase {
    event VaultRoleAdded(bytes32 roleId, string label, address sender);
    event VaultRoleLabelUpdated(bytes32 roleId, string label, address sender);
    event VaultRoleActiveUpdated(bytes32 roleId, bool active, address sender);

    bytes32 internal constant NEW_ROLE = keccak256("COMPLIANCE_OFFICER");

    function _unauthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account_, role_);
    }

    // ------------------------------------------------------------ K1 initialize

    function testInitializeGrantsAdminOnly() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertFalse(registry.hasRole(registry.ROLES_CATALOG_MANAGER_ROLE(), admin));
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function testInitializeRevertsOnZeroAdmin() public {
        address impl = address(implementation);
        vm.expectRevert(abi.encodeWithSelector(Errors.WrongAddress.selector));
        new ERC1967Proxy(impl, abi.encodeCall(VaultRoleRegistry.initialize, (address(0))));
        // positive twin
        VaultRoleRegistry fresh = _deployRegistry(makeAddr("otherAdmin"));
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), makeAddr("otherAdmin")));
    }

    function testInitializeTwiceReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        registry.initialize(stranger);
    }

    function testInitializeOnImplementationReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Initializable.InvalidInitialization.selector));
        implementation.initialize(admin);
    }

    function testAdminAndCatalogueRolesAreEnumerable() public view {
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        assertEq(registry.getRoleMemberCount(adminRole), 1, "admin count");
        assertEq(registry.getRoleMember(adminRole, 0), admin, "admin member");
        assertEq(registry.getRoleMemberCount(catalogRole), 1, "catalog count");
        assertEq(registry.getRoleMember(catalogRole, 0), catalogManager, "catalog member");
    }

    // ------------------------------------------------------------ K9 remover role

    function testRemoverRoleIsEnumerableAndNotSeeded() public {
        bytes32 removerRole = registry.VAULT_REMOVER_ROLE();
        assertEq(removerRole, keccak256("VAULT_REMOVER_ROLE"), "role id");
        assertEq(registry.getRoleMemberCount(removerRole), 1, "remover count");
        assertEq(registry.getRoleMember(removerRole, 0), remover, "remover member");
        assertFalse(registry.hasRole(removerRole, admin), "admin does not hold the remover role");

        // initialize does not seed the role, not even for the admin
        address freshAdmin = makeAddr("freshAdmin");
        VaultRoleRegistry fresh = _deployRegistry(freshAdmin);
        assertEq(fresh.getRoleMemberCount(removerRole), 0, "fresh proxy has no remover");
        assertFalse(fresh.hasRole(removerRole, freshAdmin), "fresh admin is not a remover");
        assertTrue(fresh.hasRole(fresh.DEFAULT_ADMIN_ROLE(), freshAdmin), "fresh admin is admin");
    }

    function testOnlyAdminGrantsAndRevokesRemoverRole() public {
        bytes32 removerRole = registry.VAULT_REMOVER_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        address newRemover = makeAddr("newRemover");

        address[3] memory callers = [stranger, catalogManager, remover];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], adminRole));
            registry.grantRole(removerRole, newRemover);

            vm.prank(callers[i]);
            vm.expectRevert(_unauthorized(callers[i], adminRole));
            registry.revokeRole(removerRole, remover);
        }
        assertFalse(registry.hasRole(removerRole, newRemover), "nothing granted");
        assertTrue(registry.hasRole(removerRole, remover), "nothing revoked");

        vm.expectEmit(true, true, true, true, address(registry));
        emit IAccessControl.RoleGranted(removerRole, newRemover, admin);
        vm.prank(admin);
        registry.grantRole(removerRole, newRemover);
        assertTrue(registry.hasRole(removerRole, newRemover));
        assertEq(registry.getRoleMemberCount(removerRole), 2);

        vm.expectEmit(true, true, true, true, address(registry));
        emit IAccessControl.RoleRevoked(removerRole, remover, admin);
        vm.prank(admin);
        registry.revokeRole(removerRole, remover);
        assertFalse(registry.hasRole(removerRole, remover));
        assertEq(registry.getRoleMemberCount(removerRole), 1);

        // the revoked remover can no longer remove, the new one can
        _grantAs(atomistA, vaultA, registry.VAULT_ROLE_RISK_MANAGER(), accounts[0]);
        vm.prank(remover);
        vm.expectRevert(_unauthorized(remover, removerRole));
        registry.removeVault(vaultA, 10);
        assertEq(_removeAs(newRemover, vaultA, 10), 0, "new remover clears the vault");
    }

    // ------------------------------------------------------------ ERC-7201 storage binding

    /// @dev Reads the real storage of the proxy at the ERC-7201 namespace: `roleIds._values` length at the base slot,
    /// `vaults._values` length at base + 3 (struct layout of VaultRoleRegistryStorageLib.Storage).
    function testStorageLivesAtErc7201Namespace() public {
        uint256 slot = uint256(keccak256(abi.encode(uint256(keccak256("io.ipor.vaultRoleRegistry.Storage")) - 1))) &
            ~uint256(0xff);
        assertEq(uint256(vm.load(address(registry), bytes32(slot))), 3, "seeded roleIds length");
        assertEq(uint256(vm.load(address(registry), bytes32(slot + 3))), 0, "vaults length before grant");

        _grantAs(atomistA, vaultA, registry.VAULT_ROLE_RISK_MANAGER(), accounts[0]);
        assertEq(uint256(vm.load(address(registry), bytes32(slot + 3))), 1, "vaults length after grant");

        vm.prank(catalogManager);
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");
        assertEq(uint256(vm.load(address(registry), bytes32(slot))), 4, "roleIds length after add");
    }

    // ------------------------------------------------------------ K2 seeded roles

    function testSeededRolesOnFreshProxy() public {
        address newAdmin = makeAddr("freshAdmin");
        // The proxy is the next contract created by this test, bind the seed events to its address.
        address proxy = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(false, false, false, true, proxy);
        emit VaultRoleAdded(keccak256("RISK_MANAGER"), "Risk Manager", address(this));
        vm.expectEmit(false, false, false, true, proxy);
        emit VaultRoleAdded(keccak256("RISK_MONITOR"), "Risk Monitor", address(this));
        vm.expectEmit(false, false, false, true, proxy);
        emit VaultRoleAdded(keccak256("BRAND_MANAGER"), "Brand Manager", address(this));
        VaultRoleRegistry fresh = _deployRegistry(newAdmin);
        assertEq(address(fresh), proxy, "proxy address");

        VaultRoleDefinition[] memory roles = fresh.getVaultRoles();
        assertEq(roles.length, 3, "count");
        assertEq(roles[0].roleId, keccak256("RISK_MANAGER"));
        assertEq(roles[0].label, "Risk Manager");
        assertTrue(roles[0].active);
        assertEq(roles[1].roleId, keccak256("RISK_MONITOR"));
        assertEq(roles[1].label, "Risk Monitor");
        assertTrue(roles[1].active);
        assertEq(roles[2].roleId, keccak256("BRAND_MANAGER"));
        assertEq(roles[2].label, "Brand Manager");
        assertTrue(roles[2].active);
    }

    function testSeededRoleConstantsAndLookups() public view {
        assertEq(registry.VAULT_ROLE_RISK_MANAGER(), keccak256("RISK_MANAGER"));
        assertEq(registry.VAULT_ROLE_RISK_MONITOR(), keccak256("RISK_MONITOR"));
        assertEq(registry.VAULT_ROLE_BRAND_MANAGER(), keccak256("BRAND_MANAGER"));
        assertTrue(registry.isVaultRoleDefined(registry.VAULT_ROLE_RISK_MANAGER()));
        assertEq(registry.getVaultRole(registry.VAULT_ROLE_BRAND_MANAGER()).label, "Brand Manager");
        assertEq(registry.getVaultRoles().length, 3);
    }

    // ------------------------------------------------------------ K1 admin grants

    function testOnlyAdminGrantsCatalogManagerRole() public {
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, adminRole));
        registry.grantRole(catalogRole, stranger);

        vm.prank(catalogManager);
        vm.expectRevert(_unauthorized(catalogManager, adminRole));
        registry.grantRole(catalogRole, stranger);

        vm.prank(admin);
        registry.grantRole(catalogRole, stranger);
        assertTrue(registry.hasRole(catalogRole, stranger));
    }

    function testOnlyAdminRevokesCatalogManagerRole() public {
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, adminRole));
        registry.revokeRole(catalogRole, catalogManager);

        vm.prank(admin);
        registry.revokeRole(catalogRole, catalogManager);
        assertFalse(registry.hasRole(catalogRole, catalogManager));

        vm.prank(catalogManager);
        vm.expectRevert(_unauthorized(catalogManager, catalogRole));
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");
    }

    // ------------------------------------------------------------ K3 catalogue access control

    function testAddVaultRoleAccessControl() public {
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, catalogRole));
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");

        // the admin alone is not enough
        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, catalogRole));
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");

        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleAdded(NEW_ROLE, "Compliance Officer", catalogManager);
        vm.prank(catalogManager);
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");

        VaultRoleDefinition memory def = registry.getVaultRole(NEW_ROLE);
        assertEq(def.roleId, NEW_ROLE);
        assertEq(def.label, "Compliance Officer");
        assertTrue(def.active);
        assertEq(registry.getVaultRoles().length, 4);
        assertEq(registry.getVaultRoles()[3].roleId, NEW_ROLE, "appended last");
    }

    function testUpdateVaultRoleLabelAccessControl() public {
        bytes32 roleId = registry.VAULT_ROLE_RISK_MANAGER();
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, catalogRole));
        registry.updateVaultRoleLabel(roleId, "X");

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, catalogRole));
        registry.updateVaultRoleLabel(roleId, "X");

        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleLabelUpdated(roleId, "X", catalogManager);
        vm.prank(catalogManager);
        registry.updateVaultRoleLabel(roleId, "X");
        assertEq(registry.getVaultRole(roleId).label, "X");
    }

    function testSetVaultRoleActiveAccessControl() public {
        bytes32 roleId = registry.VAULT_ROLE_RISK_MONITOR();
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, catalogRole));
        registry.setVaultRoleActive(roleId, false);

        vm.prank(admin);
        vm.expectRevert(_unauthorized(admin, catalogRole));
        registry.setVaultRoleActive(roleId, false);

        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleActiveUpdated(roleId, false, catalogManager);
        vm.prank(catalogManager);
        registry.setVaultRoleActive(roleId, false);
        assertFalse(registry.getVaultRole(roleId).active);
    }

    function testAdminWithCatalogRoleCanManageCatalogue() public {
        bytes32 catalogRole = registry.ROLES_CATALOG_MANAGER_ROLE();
        vm.startPrank(admin);
        registry.grantRole(catalogRole, admin);
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");
        vm.stopPrank();
        assertTrue(registry.isVaultRoleDefined(NEW_ROLE));
    }

    // ------------------------------------------------------------ K3 catalogue validation

    function testAddVaultRoleRejectsZeroId() public {
        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.InvalidVaultRoleId.selector));
        registry.addVaultRole(bytes32(0), "Zero");
    }

    function testAddVaultRoleRejectsDuplicate() public {
        bytes32 roleId = registry.VAULT_ROLE_RISK_MANAGER();
        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleAlreadyDefined.selector, roleId));
        registry.addVaultRole(roleId, "Other label");

        vm.prank(catalogManager);
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");
        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleAlreadyDefined.selector, NEW_ROLE));
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");
    }

    function testAddVaultRoleLabelBounds() public {
        bytes memory tooLong = new bytes(65);
        bytes memory maxLen = new bytes(64);
        for (uint256 i; i < 65; ++i) {
            tooLong[i] = "a";
        }
        for (uint256 i; i < 64; ++i) {
            maxLen[i] = "b";
        }

        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.InvalidVaultRoleLabel.selector));
        registry.addVaultRole(NEW_ROLE, "");

        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.InvalidVaultRoleLabel.selector));
        registry.addVaultRole(NEW_ROLE, string(tooLong));

        // 64 bytes is accepted
        vm.prank(catalogManager);
        registry.addVaultRole(NEW_ROLE, string(maxLen));
        assertEq(bytes(registry.getVaultRole(NEW_ROLE).label).length, 64);
    }

    function testUpdateVaultRoleLabelBounds() public {
        bytes32 roleId = registry.VAULT_ROLE_RISK_MANAGER();
        bytes memory tooLong = new bytes(65);
        bytes memory maxLen = new bytes(64);
        for (uint256 i; i < 65; ++i) {
            tooLong[i] = "a";
        }
        for (uint256 i; i < 64; ++i) {
            maxLen[i] = "b";
        }

        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.InvalidVaultRoleLabel.selector));
        registry.updateVaultRoleLabel(roleId, "");

        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.InvalidVaultRoleLabel.selector));
        registry.updateVaultRoleLabel(roleId, string(tooLong));

        vm.prank(catalogManager);
        registry.updateVaultRoleLabel(roleId, string(maxLen));
        assertEq(registry.getVaultRole(roleId).label, string(maxLen));
        assertEq(registry.MAX_VAULT_ROLE_LABEL_LENGTH(), 64);
    }

    function testUpdateAndSetActiveRejectUnknownRole() public {
        bytes32 unknown = keccak256("UNKNOWN");
        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.updateVaultRoleLabel(unknown, "Label");

        vm.prank(catalogManager);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.setVaultRoleActive(unknown, false);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.getVaultRole(unknown);

        // positive twin: known role works
        bytes32 known = registry.VAULT_ROLE_RISK_MANAGER();
        vm.prank(catalogManager);
        registry.setVaultRoleActive(known, false);
    }

    function testUpdateAndSetActiveAreIdempotentAndEmit() public {
        bytes32 roleId = registry.VAULT_ROLE_RISK_MANAGER();
        for (uint256 i; i < 2; ++i) {
            vm.expectEmit(false, false, false, true, address(registry));
            emit VaultRoleLabelUpdated(roleId, "Risk Manager", catalogManager);
            vm.prank(catalogManager);
            registry.updateVaultRoleLabel(roleId, "Risk Manager");

            vm.expectEmit(false, false, false, true, address(registry));
            emit VaultRoleActiveUpdated(roleId, true, catalogManager);
            vm.prank(catalogManager);
            registry.setVaultRoleActive(roleId, true);
        }
        assertEq(registry.getVaultRole(roleId).label, "Risk Manager");
        assertTrue(registry.getVaultRole(roleId).active);
        assertEq(registry.getVaultRoles().length, 3);
    }

    function testDeactivatedRoleStaysInCatalogue() public {
        bytes32 roleId = registry.VAULT_ROLE_BRAND_MANAGER();
        vm.prank(catalogManager);
        registry.setVaultRoleActive(roleId, false);
        assertEq(registry.getVaultRoles().length, 3);
        assertTrue(registry.isVaultRoleDefined(roleId));
        assertFalse(registry.getVaultRole(roleId).active);

        vm.prank(catalogManager);
        registry.setVaultRoleActive(roleId, true);
        assertTrue(registry.getVaultRole(roleId).active);
    }

    // ------------------------------------------------------------ K3 label change keeps assignments

    function testLabelChangePreservesAssignmentsOnTwoVaults() public {
        bytes32 riskManager = registry.VAULT_ROLE_RISK_MANAGER();
        bytes32 riskMonitor = registry.VAULT_ROLE_RISK_MONITOR();
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[0]);
        _grantAs(atomistA, vaultA, riskManager, accounts[1]);
        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
        _grantAs(atomistB, vaultB, riskManager, accounts[2]);

        AccountRoles[] memory snapA = _snapshot(vaultA);
        AccountRoles[] memory snapB = _snapshot(vaultB);
        address[] memory vaults0 = _sortedAccountVaults(accounts[0]);
        address[] memory vaults1 = _sortedAccountVaults(accounts[1]);
        address[] memory vaults2 = _sortedAccountVaults(accounts[2]);
        address[] memory holdersA = _sortedRoleHolders(vaultA, riskManager);
        address[] memory holdersB = _sortedRoleHolders(vaultB, riskManager);
        address[] memory allVaults = _sortedVaults();
        assertEq(vaults0.length, 2);
        assertEq(holdersA.length, 2);

        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleLabelUpdated(riskManager, "Chief Risk Officer", catalogManager);
        vm.prank(catalogManager);
        registry.updateVaultRoleLabel(riskManager, "Chief Risk Officer");

        assertEq(registry.getVaultRole(riskManager).label, "Chief Risk Officer");
        VaultRoleDefinition[] memory roles = registry.getVaultRoles();
        assertEq(roles[0].roleId, riskManager);
        assertEq(roles[0].label, "Chief Risk Officer");
        assertEq(roles[1].label, "Risk Monitor");

        _assertSnapshotsEq(snapA, _snapshot(vaultA));
        _assertSnapshotsEq(snapB, _snapshot(vaultB));
        _assertAddressesEq(vaults0, _sortedAccountVaults(accounts[0]));
        _assertAddressesEq(vaults1, _sortedAccountVaults(accounts[1]));
        _assertAddressesEq(vaults2, _sortedAccountVaults(accounts[2]));
        _assertAddressesEq(holdersA, _sortedRoleHolders(vaultA, riskManager));
        _assertAddressesEq(holdersB, _sortedRoleHolders(vaultB, riskManager));
        _assertAddressesEq(allVaults, _sortedVaults());
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultB, riskManager, accounts[2]));
    }

    function _assertAddressesEq(address[] memory a_, address[] memory b_) internal pure {
        assertEq(a_.length, b_.length, "addresses: length");
        for (uint256 i; i < a_.length; ++i) {
            assertEq(a_[i], b_[i], "addresses: item");
        }
    }

    // ------------------------------------------------------------ upgrade

    function testUpgradeOnlyByAdminAndPreservesState() public {
        bytes32 riskManager = registry.VAULT_ROLE_RISK_MANAGER();
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistB, vaultB, registry.VAULT_ROLE_BRAND_MANAGER(), accounts[1]);
        vm.prank(catalogManager);
        registry.addVaultRole(NEW_ROLE, "Compliance Officer");

        VaultRoleDefinition[] memory rolesBefore = registry.getVaultRoles();
        AccountRoles[] memory snapA = _snapshot(vaultA);
        AccountRoles[] memory snapB = _snapshot(vaultB);
        address[] memory vaultsBefore = _sortedVaults();

        address newImpl = address(new VaultRoleRegistry());

        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(stranger);
        vm.expectRevert(_unauthorized(stranger, adminRole));
        registry.upgradeToAndCall(newImpl, "");

        vm.prank(catalogManager);
        vm.expectRevert(_unauthorized(catalogManager, adminRole));
        registry.upgradeToAndCall(newImpl, "");

        vm.prank(admin);
        registry.upgradeToAndCall(newImpl, "");

        // implementation slot changed (ERC1967)
        bytes32 slot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        assertEq(address(uint160(uint256(vm.load(address(registry), slot)))), newImpl);

        VaultRoleDefinition[] memory rolesAfter = registry.getVaultRoles();
        assertEq(rolesAfter.length, rolesBefore.length);
        for (uint256 i; i < rolesAfter.length; ++i) {
            assertEq(rolesAfter[i].roleId, rolesBefore[i].roleId);
            assertEq(rolesAfter[i].label, rolesBefore[i].label);
            assertEq(rolesAfter[i].active, rolesBefore[i].active);
        }
        _assertSnapshotsEq(snapA, _snapshot(vaultA));
        _assertSnapshotsEq(snapB, _snapshot(vaultB));
        _assertAddressesEq(vaultsBefore, _sortedVaults());
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.ROLES_CATALOG_MANAGER_ROLE(), catalogManager));

        // still operational after the upgrade
        _grantAs(atomistA, vaultA, registry.VAULT_ROLE_RISK_MONITOR(), accounts[3]);
        assertTrue(registry.hasVaultRole(vaultA, registry.VAULT_ROLE_RISK_MONITOR(), accounts[3]));
    }

    function testUpgradePreservesRemoverRoleAndRemovalWorks() public {
        bytes32 riskManager = registry.VAULT_ROLE_RISK_MANAGER();
        bytes32 removerRole = registry.VAULT_REMOVER_ROLE();
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, registry.VAULT_ROLE_RISK_MONITOR(), accounts[1]);
        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 2, "two vaults before the upgrade");

        address newImpl = address(new VaultRoleRegistry());
        vm.prank(admin);
        registry.upgradeToAndCall(newImpl, "");

        assertTrue(registry.hasRole(removerRole, remover), "remover role survives the upgrade");
        assertEq(registry.getRoleMemberCount(removerRole), 1, "remover count survives the upgrade");
        assertEq(registry.getRoleMember(removerRole, 0), remover, "remover member survives the upgrade");

        assertEq(_removeAs(remover, vaultA, 10), 0, "removal works on the new implementation");
        assertEq(registry.getVaultAccountsCount(vaultA), 0, "vaultA emptied");
        assertEq(registry.getVaultsCount(), 1, "vaultA left the list");
        assertEq(registry.getVaults()[0], vaultB, "vaultB untouched");
        assertTrue(registry.hasVaultRole(vaultB, riskManager, accounts[0]), "vaultB assignment kept");
    }
}
