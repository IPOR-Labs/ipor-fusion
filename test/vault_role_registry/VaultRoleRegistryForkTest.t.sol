// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {VaultRoleRegistry} from "../../contracts/vault_role_registry/VaultRoleRegistry.sol";
import {IVaultRoleRegistry, AccountRoles} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";

/// @notice Runs the atomist check (`authority()` -> `hasRole(ATOMIST_ROLE)`) of the VaultRoleRegistry against a real
/// Ethereum PlasmaVault and its real AccessManager.
contract VaultRoleRegistryForkTest is Test {
    uint256 private constant FORK_BLOCK = 23900000;

    address private constant VAULT = 0xB8a451107A9f87FDe481D4D686247D6e43Ed715e;
    address private constant ATOMIST = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    address private constant ALPHA = 0x6d3BE3f86FB1139d0c9668BD552f05fcB643E6e6;

    address private constant REGISTRY_ADMIN = address(0xAD11);
    address private constant REMOVER = address(0xBE11);
    address private constant ACCOUNT = address(0xACC1);

    VaultRoleRegistry private _registry;
    bytes32 private _riskManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), FORK_BLOCK);

        // Preconditions on the pinned block: fail loudly instead of passing vacuously.
        address authority = IAccessManaged(VAULT).authority();
        assertTrue(authority != address(0), "vault has an access manager");
        (bool atomistHasRole, ) = IAccessManager(authority).hasRole(Roles.ATOMIST_ROLE, ATOMIST);
        assertTrue(atomistHasRole, "ATOMIST must be atomist of the vault at the pinned block");
        (bool alphaHasRole, ) = IAccessManager(authority).hasRole(Roles.ATOMIST_ROLE, ALPHA);
        assertFalse(alphaHasRole, "ALPHA must not be atomist of the vault at the pinned block");

        VaultRoleRegistry implementation = new VaultRoleRegistry();
        _registry = VaultRoleRegistry(
            address(
                new ERC1967Proxy(
                    address(implementation),
                    abi.encodeWithSignature("initialize(address)", REGISTRY_ADMIN)
                )
            )
        );
        _riskManager = _registry.VAULT_ROLE_RISK_MANAGER();
    }

    function testShouldLetRealAtomistGrantRoleOnRealVault() external {
        // given
        assertFalse(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "not granted before");

        // when
        vm.expectEmit(false, false, false, true, address(_registry));
        emit IVaultRoleRegistry.VaultRoleGranted(VAULT, _riskManager, ACCOUNT, ATOMIST);
        vm.expectEmit(false, false, false, true, address(_registry));
        emit IVaultRoleRegistry.VaultAdded(VAULT, ATOMIST);
        vm.prank(ATOMIST);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);

        // then
        assertTrue(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "granted by the atomist");
        assertEq(_registry.getVaultsCount(), 1, "vault registered");
        assertEq(_registry.getVaults()[0], VAULT, "vault address stored");
        assertEq(_registry.getVaultAccountsCount(VAULT), 1, "one account on the vault");
        AccountRoles[] memory page = _registry.getVaultAccountsWithRolesPaginated(VAULT, 0, 10);
        assertEq(page.length, 1, "page has one entry");
        assertEq(page[0].account, ACCOUNT, "page account");
        assertEq(page[0].roleIds.length, 1, "page role count");
        assertEq(page[0].roleIds[0], _riskManager, "page role");
        assertEq(_registry.getVaultAccountsWithRolesPaginated(VAULT, 1, 10).length, 0, "offset past the end");
    }

    function testShouldLetRemoverRemoveRealVaultWithoutAtomist() external {
        // given
        bytes32 removerRole = _registry.VAULT_REMOVER_ROLE();
        vm.prank(REGISTRY_ADMIN);
        _registry.grantRole(removerRole, REMOVER);
        vm.prank(ATOMIST);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);
        assertEq(_registry.getVaultsCount(), 1, "vault registered");

        // when: the remover is not an atomist of the vault, so the removal must not depend on authority()
        vm.expectCall(VAULT, abi.encodeWithSelector(IAccessManaged.authority.selector), 0);
        vm.expectEmit(false, false, false, true, address(_registry));
        emit IVaultRoleRegistry.VaultRoleRevoked(VAULT, _riskManager, ACCOUNT, REMOVER);
        vm.expectEmit(false, false, false, true, address(_registry));
        emit IVaultRoleRegistry.VaultRemoved(VAULT, REMOVER);
        vm.prank(REMOVER);
        uint256 remaining = _registry.removeVault(VAULT, 10);

        // then
        assertEq(remaining, 0, "no accounts left");
        assertFalse(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "assignment removed");
        assertEq(_registry.getVaultAccountsCount(VAULT), 0, "count is zero");
        assertEq(_registry.getVaultsCount(), 0, "vault left the list");
    }

    function testShouldRejectRemoveVaultWithoutRemoverRoleOnRealVault() external {
        // given
        bytes32 removerRole = _registry.VAULT_REMOVER_ROLE();
        vm.prank(ATOMIST);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);

        // when / then: neither ALPHA nor the real atomist holds the remover role
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ALPHA, removerRole)
        );
        vm.prank(ALPHA);
        _registry.removeVault(VAULT, 10);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, ATOMIST, removerRole)
        );
        vm.prank(ATOMIST);
        _registry.removeVault(VAULT, 10);

        assertTrue(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "nothing removed");
        assertEq(_registry.getVaultsCount(), 1, "vault still listed");
    }

    function testShouldRejectNonAtomistOnRealVault() external {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, VAULT, ALPHA));
        vm.prank(ALPHA);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);

        assertFalse(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "nothing stored");
    }

    function testShouldRejectRegistryAdminAsNonAtomistOnRealVault() external {
        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, VAULT, REGISTRY_ADMIN)
        );
        vm.prank(REGISTRY_ADMIN);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);
    }

    function testShouldLetRealAtomistRevokeRoleOnRealVault() external {
        // given
        vm.prank(ATOMIST);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);
        assertTrue(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "granted");

        // when
        vm.expectEmit(false, false, false, true, address(_registry));
        emit IVaultRoleRegistry.VaultRoleRevoked(VAULT, _riskManager, ACCOUNT, ATOMIST);
        vm.prank(ATOMIST);
        _registry.revokeVaultRole(VAULT, _riskManager, ACCOUNT);

        // then
        assertFalse(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "revoked by the atomist");
    }

    function testShouldRejectNonAtomistRevokeOnRealVault() external {
        // given
        vm.prank(ATOMIST);
        _registry.grantVaultRole(VAULT, _riskManager, ACCOUNT);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, VAULT, ALPHA));
        vm.prank(ALPHA);
        _registry.revokeVaultRole(VAULT, _riskManager, ACCOUNT);

        assertTrue(_registry.hasVaultRole(VAULT, _riskManager, ACCOUNT), "still granted");
    }
}
