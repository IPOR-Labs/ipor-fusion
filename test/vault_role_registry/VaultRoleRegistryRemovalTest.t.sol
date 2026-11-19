// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IVaultRoleRegistry, AccountRoles} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {MockVaultRoleRegistryVault} from "./mocks/MockVaultRoleRegistryVault.sol";
import {VaultRoleRegistryTestBase} from "./VaultRoleRegistryTestBase.sol";

/// @title VaultRoleRegistryRemovalTest
/// @notice VAULT_REMOVER_ROLE and `removeVault`: access control, error order, full and batched removal, dead vaults,
/// inactive roles, clean indexes, clean re-registration and cold gas per removed account.
contract VaultRoleRegistryRemovalTest is VaultRoleRegistryTestBase {
    event VaultRoleGranted(address vault, bytes32 roleId, address account, address sender);
    event VaultRoleRevoked(address vault, bytes32 roleId, address account, address sender);
    event VaultAdded(address vault, address sender);
    event VaultRemoved(address vault, address sender);

    bytes32 internal riskManager;
    bytes32 internal riskMonitor;
    bytes32 internal brandManager;
    bytes32 internal removerRole;

    function setUp() public override {
        super.setUp();
        riskManager = registry.VAULT_ROLE_RISK_MANAGER();
        riskMonitor = registry.VAULT_ROLE_RISK_MONITOR();
        brandManager = registry.VAULT_ROLE_BRAND_MANAGER();
        removerRole = registry.VAULT_REMOVER_ROLE();
    }

    // ------------------------------------------------------------------ helpers

    function _unauthorized(address account_, bytes32 role_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, account_, role_);
    }

    /// @dev Account i gets the first (i % 3) + 1 catalogue roles: 1, 2, 3, 1, 2, 3 ...
    function _rolesFor(uint256 i_) internal view returns (bytes32[] memory roles) {
        roles = new bytes32[]((i_ % 3) + 1);
        bytes32[3] memory all = [riskManager, riskMonitor, brandManager];
        for (uint256 j; j < roles.length; ++j) {
            roles[j] = all[j];
        }
    }

    function _newAccounts(uint256 n_, string memory prefix_) internal returns (address[] memory out) {
        out = new address[](n_);
        for (uint256 i; i < n_; ++i) {
            out[i] = makeAddr(string.concat(prefix_, vm.toString(i)));
        }
    }

    /// @dev Grants every account of `accts_` the roles of `_rolesFor(index)` on `vault_` as `atomist_`.
    function _populate(address atomist_, address vault_, address[] memory accts_) internal {
        for (uint256 i; i < accts_.length; ++i) {
            bytes32[] memory roles = _rolesFor(i);
            for (uint256 j; j < roles.length; ++j) {
                _grantAs(atomist_, vault_, roles[j], accts_[i]);
            }
        }
    }

    function _assertVaultClean(address vault_, address[] memory accts_) internal view {
        assertEq(registry.getVaultAccountsCount(vault_), 0, "clean: accounts count");
        assertEq(registry.getVaultAccountsWithRoles(vault_).length, 0, "clean: accounts with roles");
        bytes32[3] memory all = [riskManager, riskMonitor, brandManager];
        for (uint256 r; r < all.length; ++r) {
            assertEq(registry.getRoleHolders(vault_, all[r]).length, 0, "clean: role holders");
        }
        for (uint256 i; i < accts_.length; ++i) {
            assertEq(registry.getAccountRoles(vault_, accts_[i]).length, 0, "clean: account roles");
            address[] memory accountVaults = registry.getAccountVaults(accts_[i]);
            for (uint256 k; k < accountVaults.length; ++k) {
                assertTrue(accountVaults[k] != vault_, "clean: vault still in accountVaults");
            }
            for (uint256 r; r < all.length; ++r) {
                assertFalse(registry.hasVaultRole(vault_, all[r], accts_[i]), "clean: hasVaultRole");
            }
        }
        address[] memory vaults = registry.getVaults();
        for (uint256 k; k < vaults.length; ++k) {
            assertTrue(vaults[k] != vault_, "clean: vault still listed");
        }
    }

    function _countOf(address[] memory list_, address item_) internal pure returns (uint256 n) {
        for (uint256 i; i < list_.length; ++i) {
            if (list_[i] == item_) ++n;
        }
    }

    function _countRemoved(Vm.Log[] memory logs_) internal pure returns (uint256 n) {
        bytes32 topic = keccak256("VaultRemoved(address,address)");
        for (uint256 i; i < logs_.length; ++i) {
            if (logs_[i].topics.length > 0 && logs_[i].topics[0] == topic) ++n;
        }
    }

    // ------------------------------------------------------------------ access control

    function testShouldRejectRemoveVaultFromCallersWithoutRemoverRole() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);

        address[4] memory callers = [stranger, admin, atomistA, catalogManager];
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(_unauthorized(callers[i], removerRole));
            vm.prank(callers[i]);
            registry.removeVault(vaultA, 10);
        }
        assertEq(registry.getVaultAccountsCount(vaultA), 1, "state untouched after rejections");

        // positive twin
        assertEq(_removeAs(remover, vaultA, 10), 0, "remover passes");
        assertEq(registry.getVaultAccountsCount(vaultA), 0);
    }

    function testShouldLetAdminRevokeAndRegrantRemoverRole() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);

        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        registry.revokeRole(removerRole, remover);

        vm.expectRevert(_unauthorized(remover, removerRole));
        vm.prank(remover);
        registry.removeVault(vaultA, 1);

        vm.prank(admin);
        registry.grantRole(removerRole, remover);
        assertEq(_removeAs(remover, vaultA, 1), 1, "role restored, one account removed");

        // only the admin manages the role
        vm.expectRevert(_unauthorized(stranger, adminRole));
        vm.prank(stranger);
        registry.grantRole(removerRole, stranger);
        vm.expectRevert(_unauthorized(remover, adminRole));
        vm.prank(remover);
        registry.grantRole(removerRole, stranger);
        assertFalse(registry.hasRole(removerRole, stranger));
    }

    // ------------------------------------------------------------------ errors and check order

    function testShouldRevertOnZeroVault() public {
        vm.expectRevert(Errors.WrongAddress.selector);
        vm.prank(remover);
        registry.removeVault(address(0), 1);

        // positive twin: same call shape with a registered vault
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(_removeAs(remover, vaultA, 1), 0);
    }

    function testShouldRevertOnZeroMaxAccounts() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);

        vm.expectRevert(Errors.WrongValue.selector);
        vm.prank(remover);
        registry.removeVault(vaultA, 0);
        assertEq(registry.getVaultAccountsCount(vaultA), 1, "state untouched");

        // positive twin
        assertEq(_removeAs(remover, vaultA, 1), 0);
    }

    function testShouldRevertWithVaultNotRegisteredForFreshAndClearedVault() public {
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultNotRegistered.selector, vaultA));
        vm.prank(remover);
        registry.removeVault(vaultA, 1);

        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        assertEq(_removeAs(remover, vaultA, 1), 0, "positive twin: registered vault is removed");

        // cleared vault is not registered any more
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultNotRegistered.selector, vaultA));
        vm.prank(remover);
        registry.removeVault(vaultA, 1);
    }

    function testShouldCheckRoleBeforeInputValidationAndInputBeforeRegistration() public {
        // role first: a stranger with a zero vault and zero limit gets the access error
        vm.expectRevert(_unauthorized(stranger, removerRole));
        vm.prank(stranger);
        registry.removeVault(address(0), 0);

        // zero vault before zero limit
        vm.expectRevert(Errors.WrongAddress.selector);
        vm.prank(remover);
        registry.removeVault(address(0), 0);

        // zero limit before registration check (vaultA has no accounts)
        vm.expectRevert(Errors.WrongValue.selector);
        vm.prank(remover);
        registry.removeVault(vaultA, 0);

        // registration check last
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultNotRegistered.selector, vaultA));
        vm.prank(remover);
        registry.removeVault(vaultA, 1);
    }

    // ------------------------------------------------------------------ full removal

    function testShouldRemoveWholeVaultInOneCallWithEventOrderAndCleanIndexes() public {
        address[] memory accts = new address[](3);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        accts[2] = accounts[2];
        _populate(atomistA, vaultA, accts); // 1 + 2 + 3 assignments
        _grantAs(atomistB, vaultB, riskManager, accounts[0]); // other vault shares an account with vaultA
        AccountRoles[] memory beforeA = registry.getVaultAccountsWithRoles(vaultA);
        AccountRoles[] memory snapB = _snapshot(vaultB);
        assertEq(beforeA.length, 3);

        // accounts are removed from the end of the set, each with all its roles in getAccountRoles order
        for (uint256 k = beforeA.length; k > 0; --k) {
            AccountRoles memory entry = beforeA[k - 1];
            for (uint256 j; j < entry.roleIds.length; ++j) {
                vm.expectEmit(true, true, true, true, address(registry));
                emit VaultRoleRevoked(vaultA, entry.roleIds[j], entry.account, remover);
            }
        }
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultRemoved(vaultA, remover);

        vm.recordLogs();
        uint256 remaining = _removeAs(remover, vaultA, 3);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(remaining, 0);
        assertEq(logs.length, 6 + 1, "6 revokes + 1 VaultRemoved, nothing else");
        assertEq(logs[6].topics[0], keccak256("VaultRemoved(address,address)"), "VaultRemoved is the last event");
        assertEq(_countRemoved(logs), 1, "exactly one VaultRemoved");

        _assertVaultClean(vaultA, accts);
        address[] memory vaults = _sortedVaults();
        assertEq(vaults.length, 1);
        assertEq(vaults[0], vaultB, "other vault stays listed");
        _assertSnapshotsEq(_snapshot(vaultB), snapB);
        address[] memory a0Vaults = registry.getAccountVaults(accounts[0]);
        assertEq(a0Vaults.length, 1);
        assertEq(a0Vaults[0], vaultB, "shared account keeps the other vault");
        assertTrue(registry.hasVaultRole(vaultB, riskManager, accounts[0]));
    }

    function testShouldTreatMaxAccountsAboveCountAsAll() public {
        address[] memory accts = _newAccounts(2, "big");
        _populate(atomistA, vaultA, accts);

        vm.recordLogs();
        assertEq(_removeAs(remover, vaultA, type(uint256).max), 0);
        assertEq(_countRemoved(vm.getRecordedLogs()), 1);
        _assertVaultClean(vaultA, accts);
    }

    // ------------------------------------------------------------------ batched removal

    function testShouldRemoveInBatchesKeepingPrefixOrderAndEmitVaultRemovedOnlyAtTheEnd() public {
        address[] memory accts = _newAccounts(5, "batch");
        _populate(atomistA, vaultA, accts);
        AccountRoles[] memory before = registry.getVaultAccountsWithRoles(vaultA);
        assertEq(before.length, 5);

        vm.recordLogs();
        uint256 remaining = _removeAs(remover, vaultA, 2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(remaining, 3, "3 accounts left");
        assertEq(_countRemoved(logs), 0, "no VaultRemoved on a partial removal");
        // accounts 4 (index 4 -> 2 roles) and 3 (index 3 -> 1 role)
        assertEq(logs.length, before[4].roleIds.length + before[3].roleIds.length, "only revokes emitted");

        // the vault is still listed and the remaining prefix keeps its order
        assertEq(_countOf(registry.getVaults(), vaultA), 1, "vault still listed");
        AccountRoles[] memory after1 = registry.getVaultAccountsWithRoles(vaultA);
        assertEq(after1.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(after1[i].account, before[i].account, "prefix account order unchanged");
            assertEq(after1[i].roleIds.length, before[i].roleIds.length, "prefix roles count");
            for (uint256 j; j < after1[i].roleIds.length; ++j) {
                assertEq(after1[i].roleIds[j], before[i].roleIds[j], "prefix roles order");
            }
        }
        // removed accounts are gone from every index while the vault is still registered
        for (uint256 i = 3; i < 5; ++i) {
            assertEq(registry.getAccountRoles(vaultA, accts[i]).length, 0);
            assertEq(registry.getAccountVaults(accts[i]).length, 0);
        }

        // the next call finishes the job
        vm.recordLogs();
        remaining = _removeAs(remover, vaultA, 10);
        assertEq(remaining, 0);
        assertEq(_countRemoved(vm.getRecordedLogs()), 1, "VaultRemoved once at the end");
        _assertVaultClean(vaultA, accts);

        // and the vault is gone for another call
        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultNotRegistered.selector, vaultA));
        vm.prank(remover);
        registry.removeVault(vaultA, 1);
    }

    function testShouldRemoveOneAccountPerCall() public {
        address[] memory accts = _newAccounts(3, "step");
        _populate(atomistA, vaultA, accts);

        assertEq(_removeAs(remover, vaultA, 1), 2);
        assertEq(registry.getVaultAccountsCount(vaultA), 2);
        assertEq(_removeAs(remover, vaultA, 1), 1);
        assertEq(registry.getVaultAccountsCount(vaultA), 1);
        assertEq(registry.getVaults().length, 1, "still listed with one account");
        vm.recordLogs();
        assertEq(_removeAs(remover, vaultA, 1), 0);
        assertEq(_countRemoved(vm.getRecordedLogs()), 1);
        _assertVaultClean(vaultA, accts);
    }

    // ------------------------------------------------------------------ dead vaults

    function testShouldClearVaultWithoutCodeWhileAtomistPathReverts() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);
        // positive twin: the atomist path works while the vault is alive
        _revokeAs(atomistA, vaultA, riskMonitor, accounts[1]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);

        vm.etch(vaultA, "");

        vm.expectRevert(bytes(""));
        vm.prank(atomistA);
        registry.revokeVaultRole(vaultA, riskManager, accounts[0]);
        assertEq(registry.getVaultAccountsCount(vaultA), 2, "atomist path changed nothing");

        assertEq(_removeAs(remover, vaultA, 10), 0, "remover clears the vault without code");
        address[] memory accts = new address[](2);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        _assertVaultClean(vaultA, accts);
    }

    function testShouldClearVaultWithRevertingAuthorityWhileAtomistPathReverts() public {
        _grantAs(atomistB, vaultB, riskManager, accounts[0]);
        _grantAs(atomistB, vaultB, brandManager, accounts[1]);

        vm.mockCallRevert(vaultB, abi.encodeWithSelector(IAccessManaged.authority.selector), "");

        vm.expectRevert(bytes(""));
        vm.prank(atomistB);
        registry.revokeVaultRole(vaultB, riskManager, accounts[0]);
        assertEq(registry.getVaultAccountsCount(vaultB), 2, "atomist path changed nothing");

        assertEq(_removeAs(remover, vaultB, 10), 0, "remover clears the vault with reverting authority()");
        address[] memory accts = new address[](2);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        _assertVaultClean(vaultB, accts);
    }

    function testShouldClearVaultWhoseAtomistLostTheRole() public {
        _grantAs(atomistA, vaultA, riskManager, accounts[0]);
        _grantAs(atomistA, vaultA, riskMonitor, accounts[1]);

        managerA.revokeRole(Roles.ATOMIST_ROLE, atomistA);

        vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.CallerNotVaultAtomist.selector, vaultA, atomistA));
        vm.prank(atomistA);
        registry.revokeVaultRole(vaultA, riskManager, accounts[0]);

        assertEq(_removeAs(remover, vaultA, 10), 0, "remover clears the vault of a former atomist");
        address[] memory accts = new address[](2);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        _assertVaultClean(vaultA, accts);
    }

    // ------------------------------------------------------------------ inactive roles

    function testShouldRemoveAssignmentsOfInactiveRolesToo() public {
        address[] memory accts = new address[](3);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        accts[2] = accounts[2];
        _populate(atomistA, vaultA, accts); // riskMonitor held by accounts 1 and 2
        assertEq(registry.getRoleHolders(vaultA, riskMonitor).length, 2);

        vm.prank(catalogManager);
        registry.setVaultRoleActive(riskMonitor, false);

        // the atomist can revoke inactive roles too; the remover does not depend on the role being active
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultRoleRevoked(vaultA, riskMonitor, accounts[2], remover);
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultRoleRevoked(vaultA, riskMonitor, accounts[1], remover);
        assertEq(_removeAs(remover, vaultA, 3), 0);

        _assertVaultClean(vaultA, accts);
        assertEq(registry.getRoleHolders(vaultA, riskMonitor).length, 0, "inactive role holders cleared");
    }

    // ------------------------------------------------------------------ re-registration

    function testShouldStartCleanAfterRemovalAndReRegistration() public {
        address[] memory accts = new address[](3);
        accts[0] = accounts[0];
        accts[1] = accounts[1];
        accts[2] = accounts[2];
        _populate(atomistA, vaultA, accts);
        assertEq(_removeAs(remover, vaultA, 3), 0);
        _assertVaultClean(vaultA, accts);

        // re-registration emits VaultAdded right after VaultRoleGranted
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultRoleGranted(vaultA, riskManager, accounts[1], atomistA);
        vm.expectEmit(true, true, true, true, address(registry));
        emit VaultAdded(vaultA, atomistA);
        _grantAs(atomistA, vaultA, riskManager, accounts[1]);

        assertEq(_countOf(registry.getVaults(), vaultA), 1, "listed exactly once");
        assertEq(registry.getVaultAccountsCount(vaultA), 1);
        AccountRoles[] memory page = registry.getVaultAccountsWithRolesPaginated(vaultA, 0, 10);
        assertEq(page.length, 1);
        assertEq(page[0].account, accounts[1]);
        assertEq(page[0].roleIds.length, 1);
        assertEq(page[0].roleIds[0], riskManager);

        // a vault C built exactly the same way is indistinguishable from the re-registered vault A
        address vaultC = address(new MockVaultRoleRegistryVault(address(managerA)));
        _grantAs(atomistA, vaultC, riskManager, accounts[1]);
        _assertSnapshotsEq(_snapshot(vaultA), _snapshot(vaultC));
        assertEq(registry.getRoleHolders(vaultA, riskMonitor).length, 0, "no leftover holders");
        assertEq(registry.getRoleHolders(vaultA, brandManager).length, 0, "no leftover holders");
        assertEq(_sortedAccountVaults(accounts[1]).length, 2, "accountVaults: vaultA and vaultC");
        assertEq(registry.getAccountVaults(accounts[0]).length, 0, "account of the old state stays clean");
        assertEq(registry.getAccountVaults(accounts[2]).length, 0, "account of the old state stays clean");
    }

    // ------------------------------------------------------------------ gas (K11)

    /// @notice Cold gas of `removeVault` per removed account. Every top-level call is its own transaction, so the
    /// assignments are written by earlier transactions and the removal starts on cold storage like in production.
    /// Measured: gas inside the call (no 21k intrinsic, no calldata cost), forge 1.9.0, cancun.
    /// forge-config: default.isolate = true
    function testShouldMeasureColdGasPerRemovedAccount() public {
        uint256 n = 10;
        address[] memory threeRole = _newAccounts(n, "gasThree");
        address[] memory oneRole = _newAccounts(n, "gasOne");
        // 3 roles per account on vaultA, 1 role per account on vaultB
        for (uint256 i; i < n; ++i) {
            _grantAs(atomistA, vaultA, riskManager, threeRole[i]);
            _grantAs(atomistA, vaultA, riskMonitor, threeRole[i]);
            _grantAs(atomistA, vaultA, brandManager, threeRole[i]);
            _grantAs(atomistB, vaultB, riskManager, oneRole[i]);
        }
        assertEq(registry.getVaultAccountsCount(vaultA), n);
        assertEq(registry.getVaultAccountsCount(vaultB), n);

        uint256 gasThree = gasleft();
        uint256 remainingA = _removeAs(remover, vaultA, n);
        gasThree = (gasThree - gasleft()) / n;

        uint256 gasOne = gasleft();
        uint256 remainingB = _removeAs(remover, vaultB, n);
        gasOne = (gasOne - gasleft()) / n;

        assertEq(remainingA, 0);
        assertEq(remainingB, 0);
        assertEq(registry.getVaults().length, 0, "both vaults cleared");

        emit log_named_uint("removeVault cold gas per account (1 role, excl. 21k intrinsic and calldata)", gasOne);
        emit log_named_uint("removeVault cold gas per account (3 roles, excl. 21k intrinsic and calldata)", gasThree);

        assertGt(gasOne, 0, "measured");
        assertGt(gasThree, gasOne, "more roles cost more");
        assertLt(gasOne, 150_000, "1-role account within bound");
        assertLt(gasThree, 250_000, "3-role account within bound");
    }
}
