// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IVaultRoleRegistry, AccountRoles} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {MockVaultRoleRegistryVault} from "./mocks/MockVaultRoleRegistryVault.sol";
import {VaultRoleRegistryTestBase} from "./VaultRoleRegistryTestBase.sol";

/// @title VaultRoleRegistryAssignmentTest
/// @notice Single-call grant/revoke behaviour of the VaultRoleRegistry: atomist authorisation, duplicates, inactive
/// roles, vault validation, fake vaults and access manager delays (criteria K4-K9, K11, K12).
contract VaultRoleRegistryAssignmentTest is VaultRoleRegistryTestBase {
    bytes32 internal rm;
    bytes32 internal rmon;
    bytes32 internal bm;

    function setUp() public override {
        super.setUp();
        rm = registry.VAULT_ROLE_RISK_MANAGER();
        rmon = registry.VAULT_ROLE_RISK_MONITOR();
        bm = registry.VAULT_ROLE_BRAND_MANAGER();
    }

    // ------------------------------------------------------------ K4 (AC1)

    function testAtomistGrantsAndRevokesAllThreeRoles() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        _grantAs(atomistA, vaultA, rmon, accounts[1]);
        _grantAs(atomistA, vaultA, bm, accounts[2]);

        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, rmon, accounts[1]));
        assertTrue(registry.hasVaultRole(vaultA, bm, accounts[2]));
        assertEq(_sortedRoleHolders(vaultA, rm).length, 1);
        assertEq(_sortedRoleHolders(vaultA, rm)[0], accounts[0]);
        assertEq(registry.getVaultsCount(), 1);
        assertEq(registry.getVaults()[0], vaultA);
        assertEq(registry.getAccountVaults(accounts[2])[0], vaultA);
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 3);

        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        _revokeAs(atomistA, vaultA, rmon, accounts[1]);
        _revokeAs(atomistA, vaultA, bm, accounts[2]);

        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, rmon, accounts[1]));
        assertFalse(registry.hasVaultRole(vaultA, bm, accounts[2]));
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 0);
        assertEq(registry.getVaultsCount(), 0);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 0);
        assertEq(registry.getRoleHolders(vaultA, rm).length, 0);
    }

    // ------------------------------------------------------------ K5 (AC2)

    function testStrangerCannotGrantButAtomistCan() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        _grantAs(stranger, vaultA, rm, accounts[0]);
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));

        _grantAs(atomistA, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testStrangerCannotRevokeButAtomistCan() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        _revokeAs(stranger, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));

        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testAlphaAndOwnerWithoutAtomistRoleAreRejected() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, alphaA));
        _grantAs(alphaA, vaultA, rm, accounts[0]);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, ownerA));
        _grantAs(ownerA, vaultA, rm, accounts[0]);

        // positive twin: owner given ATOMIST in addition is accepted
        managerA.grantRole(Roles.ATOMIST_ROLE, ownerA, 0);
        _grantAs(ownerA, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testAtomistOfOtherVaultIsRejectedOnlyForForeignVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultB, atomistA));
        _grantAs(atomistA, vaultB, rm, accounts[0]);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistB));
        _grantAs(atomistB, vaultA, rm, accounts[0]);

        _grantAs(atomistB, vaultB, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultB, rm, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testAtomistWithPendingGrantDelayIsRejectedUntilEffective() public {
        managerA.setGrantDelay(Roles.ATOMIST_ROLE, 2 days);
        vm.warp(block.timestamp + managerA.minSetback() + 1);

        address pending = makeAddr("pendingAtomist");
        managerA.grantRole(Roles.ATOMIST_ROLE, pending, 0);
        (bool isMember, ) = managerA.hasRole(Roles.ATOMIST_ROLE, pending);
        assertFalse(isMember, "precondition: grant delay pending");

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, pending));
        _grantAs(pending, vaultA, rm, accounts[0]);

        vm.warp(block.timestamp + 2 days);
        _grantAs(pending, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testAtomistAfterRoleRevokedIsRejected() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        managerA.revokeRole(Roles.ATOMIST_ROLE, atomistA);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistA));
        _grantAs(atomistA, vaultA, rmon, accounts[0]);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistA));
        _revokeAs(atomistA, vaultA, rm, accounts[0]);

        // the assignment made while still atomist remains; a restored atomist works again
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        managerA.grantRole(Roles.ATOMIST_ROLE, atomistA, 0);
        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    // ------------------------------------------------------------ K6 (AC3)

    function testDuplicateGrantReverts() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);

        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleAlreadyGranted.selector, vaultA, rm, accounts[0])
        );
        _grantAs(atomistA, vaultA, rm, accounts[0]);

        // positive twins: other role, other account and other vault are fine
        _grantAs(atomistA, vaultA, rmon, accounts[0]);
        _grantAs(atomistA, vaultA, rm, accounts[1]);
        _grantAs(atomistB, vaultB, rm, accounts[0]);
        assertEq(_sortedRoleHolders(vaultA, rm).length, 2);
    }

    function testRevokeOfNotHeldRoleReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, vaultA, rm, accounts[0])
        );
        _revokeAs(atomistA, vaultA, rm, accounts[0]);

        // held on another vault only
        _grantAs(atomistB, vaultB, rm, accounts[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, vaultA, rm, accounts[0])
        );
        _revokeAs(atomistA, vaultA, rm, accounts[0]);

        // second revoke of the same assignment
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, vaultA, rm, accounts[0])
        );
        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultB, rm, accounts[0]));
    }

    // ------------------------------------------------------------ K7 (AC4)

    function testMultiRoleAccountKeepsOtherRolesAfterOneRemoved() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        _grantAs(atomistA, vaultA, rmon, accounts[0]);
        _grantAs(atomistA, vaultA, bm, accounts[0]);
        assertEq(registry.getAccountRoles(vaultA, accounts[0]).length, 3);

        _revokeAs(atomistA, vaultA, rmon, accounts[0]);

        bytes32[] memory held = _sortedAccountRoles(vaultA, accounts[0]);
        assertEq(held.length, 2);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, rmon, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, bm, accounts[0]));
        assertEq(registry.getRoleHolders(vaultA, rmon).length, 0);
        assertEq(_sortedRoleHolders(vaultA, rm)[0], accounts[0]);
        assertEq(_sortedRoleHolders(vaultA, bm)[0], accounts[0]);
        assertEq(registry.getAccountVaults(accounts[0])[0], vaultA);
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 1);

        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        _revokeAs(atomistA, vaultA, bm, accounts[0]);
        assertEq(registry.getAccountRoles(vaultA, accounts[0]).length, 0);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 0);
    }

    // ------------------------------------------------------------ K8 (AC5)

    function testRoleAddedLaterIsAssignableAndOldEntriesStayIdentical() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        _grantAs(atomistA, vaultA, bm, accounts[1]);
        _grantAs(atomistB, vaultB, rmon, accounts[0]);
        AccountRoles[] memory beforeA = _snapshot(vaultA);
        AccountRoles[] memory beforeB = _snapshot(vaultB);

        bytes32 newRole = keccak256("COMPLIANCE_OFFICER");
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, newRole));
        _grantAs(atomistA, vaultA, newRole, accounts[2]);

        vm.prank(catalogManager);
        registry.addVaultRole(newRole, "Compliance Officer");

        _assertSnapshotsEq(_snapshot(vaultA), beforeA);
        _assertSnapshotsEq(_snapshot(vaultB), beforeB);

        _grantAs(atomistA, vaultA, newRole, accounts[2]);
        assertTrue(registry.hasVaultRole(vaultA, newRole, accounts[2]));
        _grantAs(atomistB, vaultB, newRole, accounts[0]);

        // old entries still present after the new grants
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, bm, accounts[1]));
        assertTrue(registry.hasVaultRole(vaultB, rmon, accounts[0]));
    }

    // ------------------------------------------------------------ K9 (AC6, single calls)

    function testGrantAndRevokeEmitEventsWithFullData() public {
        vm.expectEmit(false, false, false, true, address(registry));
        emit IVaultRoleRegistry.VaultRoleGranted(vaultA, rm, accounts[0], atomistA);
        _grantAs(atomistA, vaultA, rm, accounts[0]);

        vm.expectEmit(false, false, false, true, address(registry));
        emit IVaultRoleRegistry.VaultRoleRevoked(vaultA, rm, accounts[0], atomistA);
        _revokeAs(atomistA, vaultA, rm, accounts[0]);

        // a second atomist is reported as the actor
        managerA.grantRole(Roles.ATOMIST_ROLE, ownerA, 0);
        vm.expectEmit(false, false, false, true, address(registry));
        emit IVaultRoleRegistry.VaultRoleGranted(vaultA, bm, accounts[3], ownerA);
        _grantAs(ownerA, vaultA, bm, accounts[3]);
    }

    // ------------------------------------------------------------ K11 (D-002)

    function testInactiveRoleCannotBeGrantedButExistingAssignmentsStay() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        vm.prank(catalogManager);
        registry.setVaultRoleActive(rm, false);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleInactive.selector, rm));
        _grantAs(atomistA, vaultA, rm, accounts[1]);
        // inactive wins over duplicate
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleInactive.selector, rm));
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        // other active roles are unaffected
        _grantAs(atomistA, vaultA, rmon, accounts[1]);

        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[1]));
    }

    function testInactiveRoleCanBeRevokedAndReactivatedRoleCanBeGranted() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        vm.prank(catalogManager);
        registry.setVaultRoleActive(rm, false);

        // revoking a not-held inactive role reports NotGranted, not Inactive
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, vaultA, rm, accounts[1])
        );
        _revokeAs(atomistA, vaultA, rm, accounts[1]);

        _revokeAs(atomistA, vaultA, rm, accounts[0]);
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));

        vm.prank(catalogManager);
        registry.setVaultRoleActive(rm, true);
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    // ------------------------------------------------------------ K12 (D-003) and validation order

    function testVaultWithoutAccessManagerReverts() public {
        address noAuthority = address(new MockVaultRoleRegistryVault(address(0)));
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.NoAccessManager.selector, noAuthority));
        _grantAs(atomistA, noAuthority, rm, accounts[0]);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.NoAccessManager.selector, noAuthority));
        _revokeAs(atomistA, noAuthority, rm, accounts[0]);
    }

    function testVaultAddressWithoutCodeReverts() public {
        address eoa = makeAddr("eoaVault");
        vm.expectRevert(bytes(""));
        _grantAs(atomistA, eoa, rm, accounts[0]);
        vm.expectRevert(bytes(""));
        _revokeAs(atomistA, eoa, rm, accounts[0]);
        assertEq(registry.getVaultsCount(), 0);
    }

    function testFakeVaultWritesOnlyUnderItsOwnAddress() public {
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        AccountRoles[] memory realBefore = _snapshot(vaultA);

        IporFusionAccessManager attackerManager = new IporFusionAccessManager(address(this), 0);
        attackerManager.grantRole(Roles.ATOMIST_ROLE, stranger, 0);
        address fakeVault = address(new MockVaultRoleRegistryVault(address(attackerManager)));

        // the attacker is no atomist of the real vault
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        _grantAs(stranger, vaultA, rm, accounts[1]);

        _grantAs(stranger, fakeVault, rm, accounts[1]);
        _grantAs(stranger, fakeVault, rm, accounts[0]);

        assertTrue(registry.hasVaultRole(fakeVault, rm, accounts[1]));
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[1]));
        _assertSnapshotsEq(_snapshot(vaultA), realBefore);
        assertEq(registry.getVaultsCount(), 2);

        // the attacker cannot revoke the real vault's assignment through the fake one
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, fakeVault, bm, accounts[0])
        );
        _revokeAs(stranger, fakeVault, bm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testAtomistWithExecutionDelayGrantsImmediately() public {
        address delayed = makeAddr("delayedAtomist");
        managerA.grantRole(Roles.ATOMIST_ROLE, delayed, 3 days);
        (bool isMember, uint32 execDelay) = managerA.hasRole(Roles.ATOMIST_ROLE, delayed);
        assertTrue(isMember);
        assertEq(execDelay, 3 days);

        _grantAs(delayed, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
        _revokeAs(delayed, vaultA, rm, accounts[0]);
        assertFalse(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testZeroVaultOrAccountReverts() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        _grantAs(atomistA, address(0), rm, accounts[0]);
        vm.expectRevert(Errors.WrongAddress.selector);
        _grantAs(atomistA, vaultA, rm, address(0));
        vm.expectRevert(Errors.WrongAddress.selector);
        _revokeAs(atomistA, address(0), rm, accounts[0]);
        vm.expectRevert(Errors.WrongAddress.selector);
        _revokeAs(atomistA, vaultA, rm, address(0));

        // zero check precedes the atomist check
        vm.expectRevert(Errors.WrongAddress.selector);
        _grantAs(stranger, vaultA, rm, address(0));

        _grantAs(atomistA, vaultA, rm, accounts[0]);
        assertTrue(registry.hasVaultRole(vaultA, rm, accounts[0]));
    }

    function testCheckOrderAtomistThenRoleDefinedThenActiveThenDuplicate() public {
        bytes32 unknown = keccak256("UNKNOWN");

        // atomist is checked before the role is looked up
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        _grantAs(stranger, vaultA, unknown, accounts[0]);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        _revokeAs(stranger, vaultA, unknown, accounts[0]);

        // then defined
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        _grantAs(atomistA, vaultA, unknown, accounts[0]);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        _revokeAs(atomistA, vaultA, unknown, accounts[0]);

        // then active, then duplicate (covered with an inactive duplicate)
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleAlreadyGranted.selector, vaultA, rm, accounts[0])
        );
        _grantAs(atomistA, vaultA, rm, accounts[0]);
        vm.prank(catalogManager);
        registry.setVaultRoleActive(rm, false);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleInactive.selector, rm));
        _grantAs(atomistA, vaultA, rm, accounts[0]);
    }
}
