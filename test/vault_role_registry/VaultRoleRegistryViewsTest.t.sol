// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {
    IVaultRoleRegistry,
    AccountRoles,
    VaultRoleDefinition
} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {MockVaultRoleRegistryVault} from "./mocks/MockVaultRoleRegistryVault.sol";
import {VaultRoleRegistryTestBase} from "./VaultRoleRegistryTestBase.sol";

/// @title VaultRoleRegistryViewsTest
/// @notice Views, pagination and batch functions (incl. full rollback of failed batches) of VaultRoleRegistry.
contract VaultRoleRegistryViewsTest is VaultRoleRegistryTestBase {
    event VaultRoleGranted(address vault, bytes32 roleId, address account, address sender);
    event VaultRoleRevoked(address vault, bytes32 roleId, address account, address sender);

    bytes32 internal riskManager;
    bytes32 internal riskMonitor;
    bytes32 internal brandManager;

    function setUp() public override {
        super.setUp();
        riskManager = registry.VAULT_ROLE_RISK_MANAGER();
        riskMonitor = registry.VAULT_ROLE_RISK_MONITOR();
        brandManager = registry.VAULT_ROLE_BRAND_MANAGER();
    }

    // ------------------------------------------------------------------ K10: catalogue views

    function testShouldListCatalogueInStableOrderWithLabelAndActive() public {
        bytes32 extra = keccak256("EXTRA");
        vm.prank(catalogManager);
        registry.addVaultRole(extra, "Extra");
        vm.prank(catalogManager);
        registry.setVaultRoleActive(riskMonitor, false);

        VaultRoleDefinition[] memory defs = registry.getVaultRoles();
        assertEq(defs.length, 4, "catalogue length");
        assertEq(defs[0].roleId, riskManager);
        assertEq(defs[0].label, "Risk Manager");
        assertTrue(defs[0].active);
        assertEq(defs[1].roleId, riskMonitor);
        assertEq(defs[1].label, "Risk Monitor");
        assertFalse(defs[1].active, "deactivated role still listed");
        assertEq(defs[2].roleId, brandManager);
        assertEq(defs[2].label, "Brand Manager");
        assertEq(defs[3].roleId, extra);
        assertEq(defs[3].label, "Extra");
        assertTrue(defs[3].active);
    }

    function testShouldReturnSingleDefinitionAndRevertOnUnknownRole() public {
        VaultRoleDefinition memory def = registry.getVaultRole(brandManager);
        assertEq(def.roleId, brandManager);
        assertEq(def.label, "Brand Manager");
        assertTrue(def.active);

        bytes32 unknown = keccak256("UNKNOWN");
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.getVaultRole(unknown);
    }

    function testShouldReportIsVaultRoleDefined() public {
        assertTrue(registry.isVaultRoleDefined(riskManager));
        assertTrue(registry.isVaultRoleDefined(riskMonitor));
        assertTrue(registry.isVaultRoleDefined(brandManager));
        assertFalse(registry.isVaultRoleDefined(keccak256("UNKNOWN")));
        assertFalse(registry.isVaultRoleDefined(bytes32(0)));

        bytes32 extra = keccak256("EXTRA");
        vm.prank(catalogManager);
        registry.addVaultRole(extra, "Extra");
        assertTrue(registry.isVaultRoleDefined(extra));
    }

    // ------------------------------------------------------------------ K10: assignment views

    function testShouldHaveEmptyViewsOnFreshRegistry() public view {
        assertEq(registry.getVaults().length, 0);
        assertEq(registry.getVaultsCount(), 0);
        assertEq(registry.getVaultsPaginated(0, 10).length, 0);
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 0);
        assertEq(registry.getAccountRoles(vaultA, accounts[0]).length, 0);
        assertEq(registry.getRoleHolders(vaultA, riskManager).length, 0);
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertEq(registry.getAccountVaults(accounts[0]).length, 0);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 0);
        assertEq(registry.getAccountVaultsPaginated(accounts[0], 0, 10).length, 0);
    }

    function testShouldExposeAssignmentsThroughAllViews() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[0]);
        _grantAs(atomistA, vaultA, riskManager, accounts[1]);
        _grantAs(atomistB, vaultB, brandManager, accounts[0]);

        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[1]));
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]));
        assertFalse(registry.hasVaultRole(vaultA, brandManager, accounts[0]), "role is per vault");
        assertTrue(registry.hasVaultRole(vaultB, brandManager, accounts[0]));

        bytes32[] memory roles = _sortedAccountRoles(vaultA, accounts[0]);
        assertEq(roles.length, 2);
        assertEq(keccak256(abi.encode(roles)), keccak256(abi.encode(_sortedPair(riskManager, riskMonitor))));

        address[] memory holders = _sortedRoleHolders(vaultA, riskManager);
        assertEq(holders.length, 2);
        assertEq(keccak256(abi.encode(holders)), keccak256(abi.encode(_sortedAddrPair(accounts[0], accounts[1]))));
        assertEq(registry.getRoleHolders(vaultA, riskMonitor).length, 1);
        assertEq(registry.getRoleHolders(vaultA, riskMonitor)[0], accounts[0]);
        assertEq(registry.getRoleHolders(vaultB, riskManager).length, 0);

        AccountRoles[] memory snap = _snapshot(vaultA);
        assertEq(snap.length, 2);
        (address first, address second) = accounts[0] < accounts[1]
            ? (accounts[0], accounts[1])
            : (accounts[1], accounts[0]);
        assertEq(snap[0].account, first);
        assertEq(snap[1].account, second);
        assertEq(snap[0].account == accounts[0] ? snap[0].roleIds.length : snap[1].roleIds.length, 2);
        assertEq(snap[0].account == accounts[1] ? snap[0].roleIds.length : snap[1].roleIds.length, 1);

        assertEq(_snapshot(vaultB).length, 1);
        assertEq(_snapshot(vaultB)[0].account, accounts[0]);
    }

    function testShouldKeepRawViewsAfterRoleDeactivation() public {
        _grantAs(atomistA, vaultA, riskMonitor, accounts[0]);
        vm.prank(catalogManager);
        registry.setVaultRoleActive(riskMonitor, false);

        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[0]));
        assertEq(registry.getAccountRoles(vaultA, accounts[0]).length, 1);
        assertEq(registry.getRoleHolders(vaultA, riskMonitor).length, 1);
        assertEq(registry.getVaultsCount(), 1);
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 1);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 1);
    }

    function testShouldTrackVaultMembershipFromFirstToLastAssignment() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 1);
        assertEq(registry.getVaults()[0], vaultA, "vault appears on first assignment");

        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);
        assertEq(registry.getVaultsCount(), 1, "second assignment keeps a single entry");

        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 2);

        _revokeAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 2, "vault stays while an assignment remains");

        _revokeAs(atomistA, vaultA, riskMonitor, accounts[1]);
        assertEq(registry.getVaultsCount(), 1, "vault disappears after last assignment");
        assertEq(registry.getVaults()[0], vaultB);
        assertEq(registry.getVaultAccountsWithRoles(vaultA).length, 0);

        _revokeAs(atomistB, vaultB, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 0);
        assertEq(registry.getVaults().length, 0);
    }

    function testShouldTrackAccountVaultsFromFirstToLastRoleOnVault() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 1);
        assertEq(registry.getAccountVaults(accounts[0])[0], vaultA);

        _grantAs(atomistA, vaultA, riskMonitor, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 1, "second role on the same vault adds no entry");

        _grantAs(atomistB, vaultB, brandManager, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 2);
        assertEq(registry.getAccountVaultsCount(accounts[1]), 0, "other account unaffected");

        _revokeAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 2, "one role left on vault A");

        _revokeAs(atomistA, vaultA, riskMonitor, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 1, "gone after last role on vault A");
        assertEq(registry.getAccountVaults(accounts[0])[0], vaultB);

        _revokeAs(atomistB, vaultB, brandManager, accounts[0]);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 0);
        assertEq(registry.getAccountVaults(accounts[0]).length, 0);
    }

    // ------------------------------------------------------------------ pagination

    function testShouldPaginateVaultsAtEdges() public {
        address[] memory vaults = _makeVaults(5);
        assertEq(registry.getVaultsCount(), 5);

        // full page
        assertEq(registry.getVaultsPaginated(0, 5).length, 5);
        // limit larger than remaining
        assertEq(registry.getVaultsPaginated(0, 100).length, 5);
        assertEq(registry.getVaultsPaginated(3, 100).length, 2);
        // offset = count - 1
        address[] memory last = registry.getVaultsPaginated(4, 10);
        assertEq(last.length, 1);
        assertEq(last[0], registry.getVaults()[4]);
        // offset == count and beyond
        assertEq(registry.getVaultsPaginated(5, 10).length, 0);
        assertEq(registry.getVaultsPaginated(500, 10).length, 0);
        assertEq(registry.getVaultsPaginated(type(uint256).max, type(uint256).max).length, 0);
        // limit 0
        assertEq(registry.getVaultsPaginated(0, 0).length, 0);
        assertEq(registry.getVaultsPaginated(2, 0).length, 0);
        // exact limit in the middle
        assertEq(registry.getVaultsPaginated(1, 2).length, 2);
        // huge limit does not overflow
        assertEq(registry.getVaultsPaginated(1, type(uint256).max).length, 4);
        assertEq(vaults.length, 5);
    }

    function testShouldReturnUnionOfVaultPagesEqualToFullList() public {
        _makeVaults(7);
        address[] memory full = registry.getVaults();
        address[] memory joined = new address[](7);
        uint256 n;
        for (uint256 offset; offset < 7; offset += 3) {
            address[] memory page = registry.getVaultsPaginated(offset, 3);
            for (uint256 i; i < page.length; ++i) {
                joined[n++] = page[i];
            }
        }
        assertEq(n, 7);
        // pages read at one state keep the list order, so they concatenate to the full list
        assertEq(keccak256(abi.encode(joined)), keccak256(abi.encode(full)));
        assertEq(keccak256(abi.encode(_sortedAddresses(joined))), keccak256(abi.encode(_sortedVaults())));
    }

    function testShouldPaginateAccountVaultsAtEdges() public {
        address account = accounts[0];
        _assignAccountToVaults(account, 4);
        assertEq(registry.getAccountVaultsCount(account), 4);

        assertEq(registry.getAccountVaultsPaginated(account, 0, 4).length, 4);
        assertEq(registry.getAccountVaultsPaginated(account, 0, 100).length, 4);
        assertEq(registry.getAccountVaultsPaginated(account, 2, 100).length, 2);
        address[] memory last = registry.getAccountVaultsPaginated(account, 3, 10);
        assertEq(last.length, 1);
        assertEq(last[0], registry.getAccountVaults(account)[3]);
        assertEq(registry.getAccountVaultsPaginated(account, 4, 10).length, 0);
        assertEq(registry.getAccountVaultsPaginated(account, 400, 10).length, 0);
        assertEq(registry.getAccountVaultsPaginated(account, 0, 0).length, 0);
        assertEq(registry.getAccountVaultsPaginated(account, 1, 2).length, 2);
        assertEq(registry.getAccountVaultsPaginated(account, 1, type(uint256).max).length, 3);
        assertEq(registry.getAccountVaultsPaginated(accounts[1], 0, 10).length, 0, "account without vaults");
    }

    function testShouldReturnUnionOfAccountVaultPagesEqualToFullList() public {
        address account = accounts[2];
        _assignAccountToVaults(account, 5);
        address[] memory full = registry.getAccountVaults(account);
        address[] memory joined = new address[](5);
        uint256 n;
        for (uint256 offset; offset < 5; offset += 2) {
            address[] memory page = registry.getAccountVaultsPaginated(account, offset, 2);
            for (uint256 i; i < page.length; ++i) {
                joined[n++] = page[i];
            }
        }
        assertEq(n, 5);
        assertEq(keccak256(abi.encode(joined)), keccak256(abi.encode(full)));
    }

    // ------------------------------------------------------------------ K9: batch happy path

    function testShouldBatchGrantAndEmitEventsInInputOrder() public {
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskMonitor;
        accs[0] = accounts[1];
        roleIds[1] = riskManager;
        accs[1] = accounts[0];
        roleIds[2] = brandManager;
        accs[2] = accounts[1];

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(false, false, false, true, address(registry));
            emit VaultRoleGranted(vaultA, roleIds[i], accs[i], atomistA);
        }
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, roleIds, accs);

        for (uint256 i; i < 3; ++i) {
            assertTrue(registry.hasVaultRole(vaultA, roleIds[i], accs[i]));
        }
        assertEq(registry.getVaultsCount(), 1);
        assertEq(registry.getAccountRoles(vaultA, accounts[1]).length, 2);
        assertEq(registry.getAccountVaultsCount(accounts[0]), 1);
    }

    function testShouldBatchRevokeAndEmitEventsInInputOrder() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);
        _grantAs(atomistA, vaultA, brandManager, accounts[1]);

        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = brandManager;
        accs[0] = accounts[1];
        roleIds[1] = riskManager;
        accs[1] = accounts[0];
        roleIds[2] = riskMonitor;
        accs[2] = accounts[1];

        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(false, false, false, true, address(registry));
            emit VaultRoleRevoked(vaultA, roleIds[i], accs[i], atomistA);
        }
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, roleIds, accs);

        for (uint256 i; i < 3; ++i) {
            assertFalse(registry.hasVaultRole(vaultA, roleIds[i], accs[i]));
        }
        assertEq(registry.getVaultsCount(), 0, "all assignments removed");
        assertEq(registry.getAccountVaultsCount(accounts[0]), 0);
        assertEq(registry.getAccountVaultsCount(accounts[1]), 0);
    }

    // ------------------------------------------------------------------ K10a: batch grant failures

    function testShouldRevertGrantBatchOnEmptyArrays() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.grantVaultRoles(vaultA, new bytes32[](0), new address[](0));
        _assertSnapEq(before_, _takeSnap());
    }

    function testShouldRevertGrantBatchOnMismatchedLengths() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](2);
        roleIds[0] = riskManager;
        roleIds[1] = riskMonitor;
        address[] memory accs = new address[](1);
        accs[0] = accounts[2];
        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.grantVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());
    }

    function testShouldRevertGrantBatchWhenCallerIsNotAtomistAndSucceedForAtomist() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        (bytes32[] memory roleIds, address[] memory accs) = _validGrantBatch();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        registry.grantVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());

        // an atomist of another vault is not an atomist of this one
        vm.prank(atomistB);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistB));
        registry.grantVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());

        // positive twin
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, roleIds, accs);
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[2]));
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[3]));
    }

    function testShouldRollBackGrantBatchOnZeroAccountAtLaterPosition() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[2];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[3];
        roleIds[2] = brandManager;
        accs[2] = address(0);

        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.grantVaultRoles(vaultA, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[2]), "earlier valid item rolled back");
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[3]), "earlier valid item rolled back");
    }

    function testShouldRollBackGrantBatchOnSamePairTwice() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[2];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[3];
        roleIds[2] = riskManager;
        accs[2] = accounts[2];

        vm.prank(atomistA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultRoleRegistry.VaultRoleAlreadyGranted.selector,
                vaultA,
                riskManager,
                accounts[2]
            )
        );
        registry.grantVaultRoles(vaultA, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[2]));
    }

    function testShouldRollBackGrantBatchWhenLaterPairIsAlreadyGranted() public {
        _seedState();
        // seed: accounts[0] holds riskManager on vault A
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskMonitor;
        accs[0] = accounts[2];
        roleIds[1] = brandManager;
        accs[1] = accounts[3];
        roleIds[2] = riskManager;
        accs[2] = accounts[0];

        vm.prank(atomistA);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultRoleRegistry.VaultRoleAlreadyGranted.selector,
                vaultA,
                riskManager,
                accounts[0]
            )
        );
        registry.grantVaultRoles(vaultA, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[2]));
        assertFalse(registry.hasVaultRole(vaultA, brandManager, accounts[3]));
    }

    // ------------------------------------------------------------------ K10a: batch revoke failures

    function testShouldRevertRevokeBatchOnEmptyArrays() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.revokeVaultRoles(vaultA, new bytes32[](0), new address[](0));
        _assertSnapEq(before_, _takeSnap());
    }

    function testShouldRevertRevokeBatchOnMismatchedLengths() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](1);
        roleIds[0] = riskManager;
        address[] memory accs = new address[](2);
        accs[0] = accounts[0];
        accs[1] = accounts[1];
        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());
    }

    function testShouldRevertRevokeBatchWhenCallerIsNotAtomistAndSucceedForAtomist() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        (bytes32[] memory roleIds, address[] memory accs) = _validRevokeBatch();

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());

        vm.prank(atomistB);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistB));
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());

        // positive twin
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]));
    }

    function testShouldRollBackRevokeBatchOnZeroAccountAtLaterPosition() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[0];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[1];
        roleIds[2] = brandManager;
        accs[2] = address(0);

        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.revokeVaultRoles(vaultA, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[0]), "earlier valid revoke rolled back");
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]), "earlier valid revoke rolled back");
    }

    function testShouldRollBackRevokeBatchOnSamePairTwice() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[0];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[1];
        roleIds[2] = riskManager;
        accs[2] = accounts[0];

        vm.prank(atomistA);
        vm.expectRevert(
            abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleNotGranted.selector, vaultA, riskManager, accounts[0])
        );
        registry.revokeVaultRoles(vaultA, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]));
    }

    // ------------------------------------------------------------------ batch check order and later-position failures

    function testShouldRejectZeroVaultInBatches() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        (bytes32[] memory grantIds, address[] memory grantAccs) = _validGrantBatch();
        (bytes32[] memory revokeIds, address[] memory revokeAccs) = _validRevokeBatch();

        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.grantVaultRoles(address(0), grantIds, grantAccs);

        vm.prank(atomistA);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.revokeVaultRoles(address(0), revokeIds, revokeAccs);

        _assertSnapEq(before_, _takeSnap());

        // positive twins: the same batches succeed on a real vault
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, grantIds, grantAccs);
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[2]));
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, revokeIds, revokeAccs);
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
    }

    function testShouldCheckBatchLengthAndZeroVaultBeforeAtomist() public {
        _seedState();
        Snap memory before_ = _takeSnap();
        (bytes32[] memory roleIds, address[] memory accs) = _validGrantBatch();

        // non-atomist, empty arrays
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.grantVaultRoles(vaultA, new bytes32[](0), new address[](0));
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.revokeVaultRoles(vaultA, new bytes32[](0), new address[](0));

        // non-atomist, mismatched arrays
        address[] memory shortAccs = new address[](1);
        shortAccs[0] = accounts[2];
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.grantVaultRoles(vaultA, roleIds, shortAccs);
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.revokeVaultRoles(vaultA, roleIds, shortAccs);

        // non-atomist, zero vault (valid lengths): WrongAddress, not CallerNotVaultAtomist
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.grantVaultRoles(address(0), roleIds, accs);
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongAddress.selector);
        registry.revokeVaultRoles(address(0), roleIds, accs);

        // length error wins over zero vault
        vm.prank(stranger);
        vm.expectRevert(Errors.WrongArrayLength.selector);
        registry.grantVaultRoles(address(0), roleIds, shortAccs);

        _assertSnapEq(before_, _takeSnap());

        // positive twin: with valid lengths and a real vault the non-atomist reaches the atomist check
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        registry.grantVaultRoles(vaultA, roleIds, accs);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, stranger));
        registry.revokeVaultRoles(vaultA, roleIds, accs);
    }

    function testShouldRevertBatchOnVaultWithoutAccessManager() public {
        address noAuthorityVault = address(new MockVaultRoleRegistryVault(address(0)));
        (bytes32[] memory roleIds, address[] memory accs) = _validGrantBatch();
        Snap memory before_ = _takeSnap();

        vm.prank(atomistA);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.NoAccessManager.selector, noAuthorityVault));
        registry.grantVaultRoles(noAuthorityVault, roleIds, accs);

        vm.prank(atomistA);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.NoAccessManager.selector, noAuthorityVault));
        registry.revokeVaultRoles(noAuthorityVault, roleIds, accs);

        _assertSnapEq(before_, _takeSnap());
        assertEq(registry.getVaultsCount(), 0);

        // positive twin: a vault with an access manager is accepted
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, roleIds, accs);
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[2]));
    }

    function testShouldRollBackGrantBatchOnUnknownOrInactiveRoleAtLaterPosition() public {
        _seedState();
        vm.prank(catalogManager);
        registry.setVaultRoleActive(brandManager, false);
        Snap memory before_ = _takeSnap();
        bytes32 unknown = keccak256("UNKNOWN");

        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[2];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[3];
        accs[2] = accounts[3];

        // inactive role at the last position
        roleIds[2] = brandManager;
        vm.prank(atomistA);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleInactive.selector, brandManager));
        registry.grantVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[2]), "earlier valid item rolled back");
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[3]), "earlier valid item rolled back");

        // unknown role at the last position
        roleIds[2] = unknown;
        vm.prank(atomistA);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.grantVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[2]), "earlier valid item rolled back");
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[3]), "earlier valid item rolled back");

        // positive twin: the same batch with an active, known role at the last position succeeds
        roleIds[2] = riskManager;
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, roleIds, accs);
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[2]));
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[3]));
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[3]));
    }

    function testShouldRollBackRevokeBatchOnUnknownRoleAtLaterPositionAndAllowInactiveRole() public {
        _seedState();
        _grantAs(atomistA, vaultA, brandManager, accounts[2]);
        Snap memory before_ = _takeSnap();
        bytes32 unknown = keccak256("UNKNOWN");

        bytes32[] memory roleIds = new bytes32[](3);
        address[] memory accs = new address[](3);
        roleIds[0] = riskManager;
        accs[0] = accounts[0];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[1];
        roleIds[2] = unknown;
        accs[2] = accounts[2];

        vm.prank(atomistA);
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.UnknownVaultRole.selector, unknown));
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        _assertSnapEq(before_, _takeSnap());
        assertTrue(registry.hasVaultRole(vaultA, riskManager, accounts[0]), "earlier valid revoke rolled back");
        assertTrue(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]), "earlier valid revoke rolled back");

        // positive twin: a deactivated (but defined) role can still be revoked in the same position
        vm.prank(catalogManager);
        registry.setVaultRoleActive(brandManager, false);
        roleIds[2] = brandManager;
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        assertFalse(registry.hasVaultRole(vaultA, riskManager, accounts[0]));
        assertFalse(registry.hasVaultRole(vaultA, riskMonitor, accounts[1]));
        assertFalse(registry.hasVaultRole(vaultA, brandManager, accounts[2]));
    }

    function testShouldReturnEmptyAccountVaultsPageAtMaxOffset() public {
        address account = accounts[0];
        _assignAccountToVaults(account, 3);
        assertEq(registry.getAccountVaultsCount(account), 3);

        assertEq(registry.getAccountVaultsPaginated(account, type(uint256).max, 1).length, 0);
        assertEq(registry.getAccountVaultsPaginated(account, type(uint256).max, type(uint256).max).length, 0);
        assertEq(registry.getAccountVaultsPaginated(account, type(uint256).max, 0).length, 0);

        // positive twin: an in-range offset with the same limit returns data
        assertEq(registry.getAccountVaultsPaginated(account, 2, type(uint256).max).length, 1);
    }

    // ------------------------------------------------------------------ vault accounts: count and pages

    function testShouldCountAndPaginateVaultAccountsAtEdges() public {
        // vault outside the registry
        assertEq(registry.getVaultAccountsCount(vaultA), 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 10).length, 0);

        // 5 accounts: the fixture has 4, the fifth is created locally
        address[] memory accs = _vaultAccountsOnVaultA(5);
        // two roles on the last account, so the compared entry carries more than one roleId
        _grantAs(atomistA, vaultA, riskMonitor, accs[4]);
        assertEq(registry.getVaultAccountsCount(vaultA), 5);
        assertEq(registry.getVaultAccountsCount(vaultA), registry.getVaultAccountsWithRoles(vaultA).length);

        // full page
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 5).length, 5);
        // limit larger than remaining
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 100).length, 5);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 3, 100).length, 2);
        // offset = count - 1 matches the last entry of the full view
        AccountRoles[] memory full = registry.getVaultAccountsWithRoles(vaultA);
        AccountRoles[] memory last = registry.getVaultAccountsWithRolesPaginated(vaultA, 4, 10);
        assertEq(last.length, 1);
        assertEq(last[0].account, full[4].account);
        assertEq(last[0].roleIds.length, 2);
        assertEq(keccak256(abi.encode(last[0].roleIds)), keccak256(abi.encode(full[4].roleIds)));
        // offset == count and beyond
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 5, 10).length, 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 500, 10).length, 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, type(uint256).max, type(uint256).max).length, 0);
        // limit 0
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 0).length, 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 2, 0).length, 0);
        // exact limit in the middle
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 1, 2).length, 2);
        // huge limit does not overflow
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 1, type(uint256).max).length, 4);
        // huge offset with limit 1 and limit 0
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, type(uint256).max, 1).length, 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, type(uint256).max, 0).length, 0);
        // another vault is unaffected
        assertEq(registry.getVaultAccountsCount(vaultB), 0);
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultB, 0, 10).length, 0);
    }

    function testShouldReturnUnionOfVaultAccountPagesEqualToFullList() public {
        address[] memory accs = _vaultAccountsOnVaultA(7);
        // 1-3 roles per account
        for (uint256 i; i < 7; ++i) {
            if (i % 3 >= 1) _grantAs(atomistA, vaultA, riskMonitor, accs[i]);
            if (i % 3 == 2) _grantAs(atomistA, vaultA, brandManager, accs[i]);
        }
        assertEq(registry.getVaultAccountsCount(vaultA), 7);

        AccountRoles[] memory full = registry.getVaultAccountsWithRoles(vaultA);
        AccountRoles[] memory joined = _joinPages(vaultA, 3);
        assertEq(joined.length, 7);
        // pages read at one state keep the list order: same account and same roleIds position by position
        for (uint256 i; i < 7; ++i) {
            assertEq(joined[i].account, full[i].account, "page order: account");
            assertEq(
                keccak256(abi.encode(joined[i].roleIds)),
                keccak256(abi.encode(full[i].roleIds)),
                "page order: roleIds"
            );
            assertEq(joined[i].roleIds.length, (i % 3) + 1, "roles per account");
        }

        // the sorted comparison matches the sorted snapshot of the full view
        _assertSnapshotsEq(_sortAccountRoles(joined), _snapshot(vaultA));
    }

    function testShouldKeepCountAndPagesConsistentAcrossGrantAndRevokeBetweenReads() public {
        address[] memory accs = _vaultAccountsOnVaultA(4);
        _assertCountAndPagesMatchFull(vaultA, 2, 4);

        // read page 0, then grant a new account between the reads
        AccountRoles[] memory page0 = registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 2);
        address fresh = makeAddr("freshAccount");
        _grantAs(atomistA, vaultA, riskManager, fresh);
        assertEq(registry.getVaultAccountsCount(vaultA), 5, "count after grant");
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 4, 1)[0].account, fresh, "new account is last");
        AccountRoles[] memory page0After = registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 2);
        assertEq(page0After[0].account, page0[0].account, "prefix unchanged by grant");
        assertEq(page0After[1].account, page0[1].account, "prefix unchanged by grant");
        _assertCountAndPagesMatchFull(vaultA, 2, 5);

        // a second role on an existing account changes neither count nor order
        _grantAs(atomistA, vaultA, riskMonitor, accs[1]);
        assertEq(registry.getVaultAccountsCount(vaultA), 5, "second role keeps the count");
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 1, 1)[0].account, accs[1], "order kept");
        // revoking one of the two roles of that account changes neither count nor order
        _revokeAs(atomistA, vaultA, riskMonitor, accs[1]);
        assertEq(registry.getVaultAccountsCount(vaultA), 5, "one role left keeps the count");
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 1, 1)[0].account, accs[1], "order kept");
        _assertCountAndPagesMatchFull(vaultA, 2, 5);

        // revoke the only role of the account at index 0: swap-and-pop moves the last account to index 0
        assertEq(registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 1)[0].account, accs[0]);
        _revokeAs(atomistA, vaultA, riskManager, accs[0]);
        assertEq(registry.getVaultAccountsCount(vaultA), 4, "count after revoke");
        AccountRoles[] memory afterSwap = registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 10);
        assertEq(afterSwap.length, 4);
        assertEq(afterSwap[0].account, fresh, "previous last account now at index 0");
        assertEq(afterSwap[1].account, accs[1], "middle accounts keep their index");
        assertEq(afterSwap[2].account, accs[2], "middle accounts keep their index");
        assertEq(afterSwap[3].account, accs[3], "middle accounts keep their index");
        _assertCountAndPagesMatchFull(vaultA, 2, 4);

        // revoke the last account: nothing else moves
        _revokeAs(atomistA, vaultA, riskManager, accs[3]);
        assertEq(registry.getVaultAccountsCount(vaultA), 3, "count after revoking the last");
        AccountRoles[] memory afterPop = registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 10);
        assertEq(afterPop.length, 3);
        assertEq(afterPop[0].account, fresh, "prefix unchanged by pop");
        assertEq(afterPop[1].account, accs[1], "prefix unchanged by pop");
        assertEq(afterPop[2].account, accs[2], "prefix unchanged by pop");
        _assertCountAndPagesMatchFull(vaultA, 2, 3);
    }

    // ------------------------------------------------------------------ role holders pagination

    function _holdersOnVaultA(uint256 n_) private returns (address[] memory accs) {
        accs = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            accs[i] = makeAddr(string.concat("holder", vm.toString(i)));
            _grantAs(atomistA, vaultA, riskManager, accs[i]);
        }
    }

    function _assertHolderPagesMatchFull(uint256 pageSize_, uint256 expectedCount_) private view {
        address[] memory full = registry.getRoleHolders(vaultA, riskManager);
        assertEq(full.length, expectedCount_, "full length");
        assertEq(registry.getRoleHoldersCount(vaultA, riskManager), full.length, "count equals full length");
        uint256 position;
        for (uint256 offset; offset < full.length; offset += pageSize_) {
            address[] memory page = registry.getRoleHoldersPaginated(vaultA, riskManager, offset, pageSize_);
            for (uint256 i; i < page.length; ++i) {
                assertEq(page[i], full[position], "page entry equals full list position");
                ++position;
            }
        }
        assertEq(position, full.length, "pages cover the full list");
    }

    function testShouldCountAndPaginateRoleHoldersAtEdges() public {
        bytes32 unknownRole = keccak256("UNKNOWN_ROLE");
        // unknown vault / role
        assertEq(registry.getRoleHoldersCount(makeAddr("noVault"), riskManager), 0);
        assertEq(registry.getRoleHoldersCount(vaultA, unknownRole), 0);
        assertEq(registry.getRoleHoldersPaginated(makeAddr("noVault"), riskManager, 0, 10).length, 0);
        assertEq(registry.getRoleHoldersPaginated(vaultA, unknownRole, 0, 10).length, 0);
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 10).length, 0);

        address[] memory accs = _holdersOnVaultA(5);
        assertEq(registry.getRoleHoldersCount(vaultA, riskManager), 5);
        assertEq(registry.getRoleHoldersCount(vaultA, riskMonitor), 0, "other role has no holders");

        // offset == count, offset > count, limit == 0
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 5, 3).length, 0, "offset == count");
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 6, 3).length, 0, "offset > count");
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 0).length, 0, "limit == 0");
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 2, 0).length, 0, "limit == 0 inside");
        // max values
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, type(uint256).max, 3).length, 0, "max offset");
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, type(uint256).max, type(uint256).max).length, 0);
        address[] memory all = registry.getRoleHoldersPaginated(vaultA, riskManager, 0, type(uint256).max);
        assertEq(all.length, 5, "max limit returns everything");
        for (uint256 i; i < 5; ++i) {
            assertEq(all[i], accs[i], "insertion order before any removal");
        }
        // partial last page
        address[] memory last = registry.getRoleHoldersPaginated(vaultA, riskManager, 3, 10);
        assertEq(last.length, 2, "partial last page");
        assertEq(last[0], accs[3]);
        assertEq(last[1], accs[4]);
        // exact middle page
        address[] memory mid = registry.getRoleHoldersPaginated(vaultA, riskManager, 1, 2);
        assertEq(mid.length, 2);
        assertEq(mid[0], accs[1]);
        assertEq(mid[1], accs[2]);
    }

    function testShouldReturnRoleHolderPagesEqualToFullList() public {
        _holdersOnVaultA(5);
        _assertHolderPagesMatchFull(1, 5);
        _assertHolderPagesMatchFull(2, 5);
        _assertHolderPagesMatchFull(3, 5);
        _assertHolderPagesMatchFull(5, 5);
        _assertHolderPagesMatchFull(100, 5);
    }

    function testShouldKeepRoleHolderCountAndPagesConsistentAcrossGrantAndRevokeBetweenReads() public {
        address[] memory accs = _holdersOnVaultA(4);
        _assertHolderPagesMatchFull(2, 4);

        address[] memory page0 = registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 2);
        address fresh = makeAddr("freshHolder");
        _grantAs(atomistA, vaultA, riskManager, fresh);
        assertEq(registry.getRoleHoldersCount(vaultA, riskManager), 5, "count after grant");
        assertEq(registry.getRoleHoldersPaginated(vaultA, riskManager, 4, 1)[0], fresh, "new holder is last");
        address[] memory page0After = registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 2);
        assertEq(page0After[0], page0[0], "prefix unchanged by grant");
        assertEq(page0After[1], page0[1], "prefix unchanged by grant");
        _assertHolderPagesMatchFull(2, 5);

        // revoke holder at index 0: swap-and-pop moves the last holder to index 0
        _revokeAs(atomistA, vaultA, riskManager, accs[0]);
        assertEq(registry.getRoleHoldersCount(vaultA, riskManager), 4, "count after revoke");
        address[] memory afterSwap = registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 10);
        assertEq(afterSwap.length, 4);
        assertEq(afterSwap[0], fresh, "previous last holder now at index 0");
        assertEq(afterSwap[1], accs[1]);
        assertEq(afterSwap[2], accs[2]);
        assertEq(afterSwap[3], accs[3]);
        _assertHolderPagesMatchFull(2, 4);

        // revoke the last holder: nothing else moves
        _revokeAs(atomistA, vaultA, riskManager, accs[3]);
        assertEq(registry.getRoleHoldersCount(vaultA, riskManager), 3, "count after revoking the last");
        address[] memory afterPop = registry.getRoleHoldersPaginated(vaultA, riskManager, 0, 10);
        assertEq(afterPop.length, 3);
        assertEq(afterPop[0], fresh);
        assertEq(afterPop[1], accs[1]);
        assertEq(afterPop[2], accs[2]);
        _assertHolderPagesMatchFull(2, 3);
    }

    function testShouldListRoleHoldersPagedAfterRoleDeactivation() public {
        _holdersOnVaultA(3);
        bytes32 roleId = riskManager;
        vm.prank(catalogManager);
        registry.setVaultRoleActive(roleId, false);
        assertEq(registry.getRoleHoldersCount(vaultA, roleId), 3, "raw count includes inactive role");
        assertEq(registry.getRoleHoldersPaginated(vaultA, roleId, 0, 10).length, 3, "raw page includes inactive role");
        _assertHolderPagesMatchFull(2, 3);
    }

    // ------------------------------------------------------------------ VaultAdded / VaultRemoved (atomist path)

    function testShouldEmitVaultAddedOnFirstGrantAndVaultRemovedOnLastRevoke() public {
        bytes32 addedTopic = IVaultRoleRegistry.VaultAdded.selector;
        bytes32 removedTopic = IVaultRoleRegistry.VaultRemoved.selector;

        // first grant: VaultRoleGranted, then VaultAdded
        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleGranted(vaultA, riskManager, accounts[0], atomistA);
        vm.expectEmit(false, false, false, true, address(registry));
        emit IVaultRoleRegistry.VaultAdded(vaultA, atomistA);
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(registry.getVaultsCount(), 1);

        // second grant on the same vault: VaultRoleGranted only
        vm.recordLogs();
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "second grant emits exactly one log");
        assertEq(logs[0].topics[0], IVaultRoleRegistry.VaultRoleGranted.selector);
        assertEq(_countLogs(logs, addedTopic), 0, "no VaultAdded on a known vault");

        // a different vault gets its own VaultAdded
        vm.recordLogs();
        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
        logs = vm.getRecordedLogs();
        assertEq(_countLogs(logs, addedTopic), 1, "VaultAdded for the second vault");
        assertEq(registry.getVaultsCount(), 2);

        // revoke that does not empty the vault: VaultRoleRevoked only
        vm.recordLogs();
        _revokeAs(atomistA, vaultA, riskManager, accounts[0]);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "non-last revoke emits exactly one log");
        assertEq(logs[0].topics[0], IVaultRoleRegistry.VaultRoleRevoked.selector);
        assertEq(registry.getVaultsCount(), 2);

        // last revoke: VaultRoleRevoked, then VaultRemoved
        vm.expectEmit(false, false, false, true, address(registry));
        emit VaultRoleRevoked(vaultA, riskMonitor, accounts[1], atomistA);
        vm.expectEmit(false, false, false, true, address(registry));
        emit IVaultRoleRegistry.VaultRemoved(vaultA, atomistA);
        vm.recordLogs();
        _revokeAs(atomistA, vaultA, riskMonitor, accounts[1]);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "last revoke emits exactly two logs");
        assertEq(logs[0].topics[0], IVaultRoleRegistry.VaultRoleRevoked.selector);
        assertEq(logs[1].topics[0], removedTopic);
        (address removedVault, address removedSender) = abi.decode(logs[1].data, (address, address));
        assertEq(removedVault, vaultA);
        assertEq(removedSender, atomistA);
        assertEq(registry.getVaultsCount(), 1);
        assertEq(registry.getVaults()[0], vaultB);
    }

    function testShouldEmitVaultAddedOnceInGrantBatchAndVaultRemovedOnceInRevokeBatch() public {
        bytes32 grantedTopic = IVaultRoleRegistry.VaultRoleGranted.selector;
        bytes32 revokedTopic = IVaultRoleRegistry.VaultRoleRevoked.selector;
        bytes32 addedTopic = IVaultRoleRegistry.VaultAdded.selector;
        bytes32 removedTopic = IVaultRoleRegistry.VaultRemoved.selector;

        bytes32[] memory roleIds = new bytes32[](3);
        roleIds[0] = riskManager;
        roleIds[1] = riskMonitor;
        roleIds[2] = riskManager;
        address[] memory accs = new address[](3);
        accs[0] = accounts[0];
        accs[1] = accounts[0];
        accs[2] = accounts[1];

        // grant batch on a fresh vault: Granted, VaultAdded, Granted, Granted
        vm.recordLogs();
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, roleIds, accs);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "three grants and one VaultAdded");
        assertEq(logs[0].topics[0], grantedTopic);
        assertEq(logs[1].topics[0], addedTopic, "VaultAdded right after the first grant");
        (address addedVault, address addedSender) = abi.decode(logs[1].data, (address, address));
        assertEq(addedVault, vaultA);
        assertEq(addedSender, atomistA);
        assertEq(logs[2].topics[0], grantedTopic);
        assertEq(logs[3].topics[0], grantedTopic);
        assertEq(_countLogs(logs, addedTopic), 1, "VaultAdded exactly once");

        // a batch on the already registered vault adds no VaultAdded
        bytes32[] memory moreRoles = new bytes32[](2);
        moreRoles[0] = brandManager;
        moreRoles[1] = brandManager;
        address[] memory moreAccs = new address[](2);
        moreAccs[0] = accounts[0];
        moreAccs[1] = accounts[1];
        vm.recordLogs();
        vm.prank(atomistA);
        registry.grantVaultRoles(vaultA, moreRoles, moreAccs);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "only the two grants");
        assertEq(_countLogs(logs, addedTopic), 0, "no VaultAdded on a known vault");
        assertEq(registry.getVaultsCount(), 1);

        // revoke batch that leaves assignments: no VaultRemoved
        vm.recordLogs();
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, moreRoles, moreAccs);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "only the two revokes");
        assertEq(_countLogs(logs, removedTopic), 0, "vault still has assignments");
        assertEq(registry.getVaultsCount(), 1);

        // revoke batch that removes everything: three revokes, VaultRemoved once, after the last one
        vm.recordLogs();
        vm.prank(atomistA);
        registry.revokeVaultRoles(vaultA, roleIds, accs);
        logs = vm.getRecordedLogs();
        assertEq(logs.length, 4, "three revokes and one VaultRemoved");
        assertEq(logs[0].topics[0], revokedTopic);
        assertEq(logs[1].topics[0], revokedTopic);
        assertEq(logs[2].topics[0], revokedTopic);
        assertEq(logs[3].topics[0], removedTopic, "VaultRemoved right after the last revoke");
        (address removedVault, address removedSender) = abi.decode(logs[3].data, (address, address));
        assertEq(removedVault, vaultA);
        assertEq(removedSender, atomistA);
        assertEq(_countLogs(logs, removedTopic), 1, "VaultRemoved exactly once");
        assertEq(registry.getVaultsCount(), 0);
        assertEq(registry.getVaultAccountsCount(vaultA), 0);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Grants riskManager on vault A to `n_` accounts (the 4 fixture accounts, then local ones) and returns them.
    function _vaultAccountsOnVaultA(uint256 n_) internal returns (address[] memory accs) {
        accs = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            accs[i] = i < accounts.length ? accounts[i] : makeAddr(string.concat("extraAccount", vm.toString(i)));
            _grantAs(atomistA, vaultA, riskManager, accs[i]);
        }
    }

    /// @dev Concatenates the pages of `vault_` read with `pageSize_` at the current state.
    function _joinPages(address vault_, uint256 pageSize_) internal view returns (AccountRoles[] memory joined) {
        uint256 count = registry.getVaultAccountsCount(vault_);
        joined = new AccountRoles[](count);
        uint256 n;
        for (uint256 offset; offset < count; offset += pageSize_) {
            AccountRoles[] memory page = registry.getVaultAccountsWithRolesPaginated(vault_, offset, pageSize_);
            for (uint256 i; i < page.length; ++i) {
                joined[n++] = page[i];
            }
        }
        assertEq(n, count, "pages cover the count");
    }

    /// @dev Asserts count == full length == `expected_` and that the joined pages equal the full list position by position.
    function _assertCountAndPagesMatchFull(address vault_, uint256 pageSize_, uint256 expected_) internal view {
        AccountRoles[] memory full = registry.getVaultAccountsWithRoles(vault_);
        assertEq(registry.getVaultAccountsCount(vault_), expected_, "count");
        assertEq(full.length, expected_, "full length");
        AccountRoles[] memory joined = _joinPages(vault_, pageSize_);
        for (uint256 i; i < expected_; ++i) {
            assertEq(joined[i].account, full[i].account, "pages == full: account");
            assertEq(
                keccak256(abi.encode(joined[i].roleIds)),
                keccak256(abi.encode(full[i].roleIds)),
                "pages == full: roleIds"
            );
        }
    }

    /// @dev Returns a copy sorted by account with each roleIds sorted (same normalisation as `_snapshot`).
    function _sortAccountRoles(AccountRoles[] memory input_) internal pure returns (AccountRoles[] memory out) {
        out = new AccountRoles[](input_.length);
        for (uint256 i; i < input_.length; ++i) {
            out[i] = AccountRoles({account: input_[i].account, roleIds: _sortedBytes32(input_[i].roleIds)});
        }
        for (uint256 i = 1; i < out.length; ++i) {
            AccountRoles memory key = out[i];
            uint256 j = i;
            while (j > 0 && out[j - 1].account > key.account) {
                out[j] = out[j - 1];
                --j;
            }
            out[j] = key;
        }
    }

    /// @dev Counts the logs whose first topic is `topic0_`.
    function _countLogs(Vm.Log[] memory logs_, bytes32 topic0_) internal pure returns (uint256 n) {
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics[0] == topic0_) ++n;
        }
    }

    struct Snap {
        AccountRoles[] vaultA;
        address[] vaults;
        address[][4] accountVaults;
        address[][3] holders;
    }

    /// @dev Seeds vault A: accounts[0] -> riskManager, accounts[1] -> riskMonitor; vault B: accounts[0] -> riskManager.
    function _seedState() internal {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);
        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
    }

    function _takeSnap() internal view returns (Snap memory s) {
        s.vaultA = _snapshot(vaultA);
        s.vaults = _sortedVaults();
        for (uint256 i; i < 4; ++i) {
            s.accountVaults[i] = _sortedAccountVaults(accounts[i]);
        }
        s.holders[0] = _sortedRoleHolders(vaultA, riskManager);
        s.holders[1] = _sortedRoleHolders(vaultA, riskMonitor);
        s.holders[2] = _sortedRoleHolders(vaultA, brandManager);
    }

    function _assertSnapEq(Snap memory a_, Snap memory b_) internal pure {
        _assertSnapshotsEq(a_.vaultA, b_.vaultA);
        assertEq(keccak256(abi.encode(a_.vaults)), keccak256(abi.encode(b_.vaults)), "vaults changed");
        for (uint256 i; i < 4; ++i) {
            assertEq(
                keccak256(abi.encode(a_.accountVaults[i])),
                keccak256(abi.encode(b_.accountVaults[i])),
                "account vaults changed"
            );
        }
        for (uint256 i; i < 3; ++i) {
            assertEq(keccak256(abi.encode(a_.holders[i])), keccak256(abi.encode(b_.holders[i])), "holders changed");
        }
    }

    function _validGrantBatch() internal view returns (bytes32[] memory roleIds, address[] memory accs) {
        roleIds = new bytes32[](2);
        accs = new address[](2);
        roleIds[0] = riskManager;
        accs[0] = accounts[2];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[3];
    }

    function _validRevokeBatch() internal view returns (bytes32[] memory roleIds, address[] memory accs) {
        roleIds = new bytes32[](2);
        accs = new address[](2);
        roleIds[0] = riskManager;
        accs[0] = accounts[0];
        roleIds[1] = riskMonitor;
        accs[1] = accounts[1];
    }

    /// @dev Creates `n_` mock vaults, each with a distinct atomist who grants riskManager to accounts[0].
    function _makeVaults(uint256 n_) internal returns (address[] memory vaults) {
        vaults = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            vaults[i] = _newVaultWithAtomist(i);
            _grantAs(_lastAtomist, vaults[i], riskManager, accounts[0]);
        }
    }

    /// @dev Gives `account_` riskManager on `n_` fresh vaults.
    function _assignAccountToVaults(address account_, uint256 n_) internal {
        for (uint256 i; i < n_; ++i) {
            address v = _newVaultWithAtomist(100 + i);
            _grantAs(_lastAtomist, v, riskManager, account_);
        }
    }

    address internal _lastAtomist;

    function _newVaultWithAtomist(uint256 salt_) internal returns (address vault) {
        _lastAtomist = makeAddr(string.concat("atomist-extra-", vm.toString(salt_)));
        IporFusionAccessManager manager = new IporFusionAccessManager(address(this), 0);
        manager.grantRole(Roles.ATOMIST_ROLE, _lastAtomist, 0);
        vault = address(new MockVaultRoleRegistryVault(address(manager)));
    }

    function _sortedPair(bytes32 a_, bytes32 b_) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](2);
        (out[0], out[1]) = a_ < b_ ? (a_, b_) : (b_, a_);
    }

    function _sortedAddrPair(address a_, address b_) internal pure returns (address[] memory out) {
        out = new address[](2);
        (out[0], out[1]) = a_ < b_ ? (a_, b_) : (b_, a_);
    }
}
