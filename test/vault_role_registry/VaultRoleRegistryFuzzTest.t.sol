// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IVaultRoleRegistry, AccountRoles} from "../../contracts/vault_role_registry/IVaultRoleRegistry.sol";
import {VaultRoleRegistryTestBase} from "./VaultRoleRegistryTestBase.sol";

/// @title VaultRoleRegistryFuzzTest
/// @notice Sequence fuzz with a ghost model (K13): after random grant / revoke / removeVault / setVaultRoleActive sequences every
/// index of the registry agrees with the model, and pagination matches the full lists.
contract VaultRoleRegistryFuzzTest is VaultRoleRegistryTestBase {
    error UnknownRegistryAccount(address account);

    uint256 private constant VAULTS = 2;
    uint256 private constant ACCOUNTS = 4;
    uint256 private constant ROLES = 4;

    address[] private _vaults;
    address[] private _atomists;
    bytes32[] private _roles;

    /// @dev Ghost model: _has[vault][account][role], _active[role]
    bool[ROLES][ACCOUNTS][VAULTS] private _has;
    bool[ROLES] private _active;

    function setUp() public override {
        super.setUp();
        bytes32 extra = keccak256("EXTRA_FUZZ_ROLE");
        vm.prank(catalogManager);
        registry.addVaultRole(extra, "Extra");

        _vaults.push(vaultA);
        _vaults.push(vaultB);
        _atomists.push(atomistA);
        _atomists.push(atomistB);
        _roles.push(registry.VAULT_ROLE_RISK_MANAGER());
        _roles.push(registry.VAULT_ROLE_RISK_MONITOR());
        _roles.push(registry.VAULT_ROLE_BRAND_MANAGER());
        _roles.push(extra);
        for (uint256 r; r < ROLES; ++r) {
            _active[r] = true;
        }
    }

    function testFuzz_RandomOperationsKeepIndexesConsistent(uint256 seed_) public {
        uint256 operations = 40 + (uint256(keccak256(abi.encode(seed_, "count"))) % 21);
        for (uint256 i; i < operations; ++i) {
            _applyRandomOperation(uint256(keccak256(abi.encode(seed_, i))));
            _assertRegistryMatchesModel();
        }
    }

    function testFuzz_PaginationMatchesFullList(uint256 offset_, uint256 limit_) public {
        // Fixed setup: account 0 holds roles on both vaults, account 1 on vault A only, account 2 on vault B only.
        _grantAs(atomistA, vaultA, _roles[0], accounts[0]);
        _grantAs(atomistB, vaultB, _roles[1], accounts[0]);
        _grantAs(atomistA, vaultA, _roles[2], accounts[1]);
        _grantAs(atomistB, vaultB, _roles[3], accounts[2]);

        offset_ = bound(offset_, 0, 6);
        // include edges: 0, small values, and very large values
        limit_ = uint256(keccak256(abi.encode(limit_))) % 3 == 0 ? limit_ : bound(limit_, 0, 6);

        _assertPage(registry.getVaults(), registry.getVaultsPaginated(offset_, limit_), offset_, limit_);
        for (uint256 a; a < ACCOUNTS; ++a) {
            _assertPage(
                registry.getAccountVaults(accounts[a]),
                registry.getAccountVaultsPaginated(accounts[a], offset_, limit_),
                offset_,
                limit_
            );
        }
        for (uint256 v; v < VAULTS; ++v) {
            _assertAccountRolesPage(
                registry.getVaultAccountsWithRoles(_vaults[v]),
                registry.getVaultAccountsWithRolesPaginated(_vaults[v], offset_, limit_),
                offset_,
                limit_
            );
        }
        // exact count edges around the full list
        uint256 count = registry.getVaultsCount();
        assertEq(count, 2, "vaults count");
        assertEq(registry.getVaultsPaginated(count, 1).length, 0, "offset == count");
        assertEq(registry.getVaultsPaginated(0, type(uint256).max).length, count, "max limit");
        assertEq(registry.getVaultsPaginated(type(uint256).max, 1).length, 0, "max offset");
    }

    // ------------------------------------------------------------------ operations

    function _applyRandomOperation(uint256 h_) private {
        uint256 kind = h_ % 10;
        uint256 v = (h_ >> 8) % VAULTS;
        uint256 a = (h_ >> 16) % ACCOUNTS;
        uint256 r = (h_ >> 24) % ROLES;

        if (kind == 8) {
            _applyRemoveVault(v, 1 + ((h_ >> 32) % ACCOUNTS));
        } else if (kind == 9) {
            bool active = ((h_ >> 32) % 2) == 1;
            vm.prank(catalogManager);
            registry.setVaultRoleActive(_roles[r], active);
            _active[r] = active;
        } else if (kind <= 4) {
            // grant
            // the registry checks the role is active before checking the assignment
            if (!_active[r]) {
                vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultRoleInactive.selector, _roles[r]));
            } else if (_has[v][a][r]) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IVaultRoleRegistry.VaultRoleAlreadyGranted.selector,
                        _vaults[v],
                        _roles[r],
                        accounts[a]
                    )
                );
            } else {
                _has[v][a][r] = true;
            }
            _grantAs(_atomists[v], _vaults[v], _roles[r], accounts[a]);
        } else {
            // revoke (allowed for inactive roles)
            if (!_has[v][a][r]) {
                vm.expectRevert(
                    abi.encodeWithSelector(
                        IVaultRoleRegistry.VaultRoleNotGranted.selector,
                        _vaults[v],
                        _roles[r],
                        accounts[a]
                    )
                );
            } else {
                _has[v][a][r] = false;
            }
            _revokeAs(_atomists[v], _vaults[v], _roles[r], accounts[a]);
        }
    }

    /// @dev removeVault(v, k): the removed suffix is read before the call, the model forgets those accounts, the
    /// returned remaining count and the order of the untouched prefix are asserted.
    function _applyRemoveVault(uint256 v_, uint256 k_) private {
        address vault = _vaults[v_];
        if (registry.getVaultAccountsCount(vault) == 0) {
            // the model must agree that the vault has no accounts
            for (uint256 a; a < ACCOUNTS; ++a) {
                for (uint256 r; r < ROLES; ++r) {
                    assertFalse(_has[v_][a][r], "model has assignments on an unregistered vault");
                }
            }
            vm.expectRevert(abi.encodeWithSelector(IVaultRoleRegistry.VaultNotRegistered.selector, vault));
            _removeAs(remover, vault, k_);
            return;
        }
        uint256 n = registry.getVaultAccountsCount(vault);
        uint256 removed = k_ < n ? k_ : n;
        AccountRoles[] memory suffix = registry.getVaultAccountsWithRolesPaginated(vault, n - removed, removed);
        AccountRoles[] memory prefixBefore = registry.getVaultAccountsWithRolesPaginated(vault, 0, n - removed);
        assertEq(suffix.length, removed, "suffix length");
        assertEq(prefixBefore.length, n - removed, "prefix length");

        uint256 remaining = _removeAs(remover, vault, k_);
        assertEq(remaining, n - removed, "removeVault remaining");

        for (uint256 i; i < suffix.length; ++i) {
            uint256 a = _accountIndex(suffix[i].account);
            for (uint256 r; r < ROLES; ++r) {
                _has[v_][a][r] = false;
            }
        }
        _assertAccountRolesEqual(registry.getVaultAccountsWithRoles(vault), prefixBefore, "prefix after removeVault");
        assertEq(registry.getVaultAccountsCount(vault), n - removed, "count after removeVault");
    }

    // ------------------------------------------------------------------ model comparison

    function _assertRegistryMatchesModel() private view {
        uint256 expectedVaults;
        for (uint256 v; v < VAULTS; ++v) {
            uint256 expectedAccounts;
            for (uint256 a; a < ACCOUNTS; ++a) {
                uint256 roleCount;
                for (uint256 r; r < ROLES; ++r) {
                    if (_has[v][a][r]) ++roleCount;
                }
                if (roleCount > 0) ++expectedAccounts;
                _assertAccountOnVault(v, a, roleCount);
            }
            for (uint256 r; r < ROLES; ++r) {
                _assertHolders(v, r);
            }
            _assertVaultSnapshot(v, expectedAccounts);
            if (expectedAccounts > 0) ++expectedVaults;
        }
        _assertVaultList(expectedVaults);
        for (uint256 a; a < ACCOUNTS; ++a) {
            _assertAccountVaults(a);
        }
    }

    function _assertAccountOnVault(uint256 v_, uint256 a_, uint256 modelRoleCount_) private view {
        bytes32[] memory held = registry.getAccountRoles(_vaults[v_], accounts[a_]);
        assertEq(held.length, modelRoleCount_, "accountRoles length");
        for (uint256 r; r < ROLES; ++r) {
            assertEq(_contains(held, _roles[r]), _has[v_][a_][r], "accountRoles membership");
            assertEq(registry.hasVaultRole(_vaults[v_], _roles[r], accounts[a_]), _has[v_][a_][r], "hasVaultRole");
        }
    }

    function _assertHolders(uint256 v_, uint256 r_) private view {
        address[] memory holders = registry.getRoleHolders(_vaults[v_], _roles[r_]);
        uint256 expected;
        for (uint256 a; a < ACCOUNTS; ++a) {
            bool inList = _contains(holders, accounts[a]);
            // account in holders(vault, role) <=> role in accountRoles(vault, account) <=> model
            assertEq(inList, _has[v_][a][r_], "roleHolders membership");
            if (_has[v_][a][r_]) ++expected;
        }
        assertEq(holders.length, expected, "roleHolders length");
        assertEq(registry.getRoleHoldersCount(_vaults[v_], _roles[r_]), holders.length, "roleHolders count");
        for (uint256 size = 1; size <= 2; ++size) {
            uint256 position;
            for (uint256 offset; offset < holders.length; offset += size) {
                address[] memory page = registry.getRoleHoldersPaginated(_vaults[v_], _roles[r_], offset, size);
                assertEq(page.length, holders.length - offset < size ? holders.length - offset : size, "page size");
                for (uint256 i; i < page.length; ++i) {
                    assertEq(page[i], holders[position], "roleHolders pages concatenation");
                    ++position;
                }
            }
            assertEq(position, holders.length, "roleHolders pages cover the list");
            assertEq(registry.getRoleHoldersPaginated(_vaults[v_], _roles[r_], holders.length, size).length, 0);
        }
    }

    function _assertVaultSnapshot(uint256 v_, uint256 expectedAccounts_) private view {
        AccountRoles[] memory snapshot = registry.getVaultAccountsWithRoles(_vaults[v_]);
        assertEq(snapshot.length, expectedAccounts_, "vaultAccounts length");
        assertEq(registry.getVaultAccountsCount(_vaults[v_]), snapshot.length, "vaultAccounts count");
        _assertAccountRolesPages(_vaults[v_], 1, snapshot);
        _assertAccountRolesPages(_vaults[v_], 2, snapshot);
        for (uint256 i; i < snapshot.length; ++i) {
            uint256 a = _accountIndex(snapshot[i].account);
            uint256 expectedRoles;
            for (uint256 r; r < ROLES; ++r) {
                if (_has[v_][a][r]) ++expectedRoles;
            }
            assertGt(expectedRoles, 0, "vaultAccounts lists account without roles");
            assertEq(snapshot[i].roleIds.length, expectedRoles, "vaultAccounts roles length");
            for (uint256 r; r < ROLES; ++r) {
                assertEq(_contains(snapshot[i].roleIds, _roles[r]), _has[v_][a][r], "vaultAccounts role membership");
            }
            for (uint256 j = i + 1; j < snapshot.length; ++j) {
                assertTrue(snapshot[i].account != snapshot[j].account, "vaultAccounts duplicate");
            }
        }
    }

    function _assertVaultList(uint256 expectedVaults_) private view {
        address[] memory list = registry.getVaults();
        assertEq(list.length, expectedVaults_, "vaults length");
        assertEq(registry.getVaultsCount(), list.length, "vaults count");
        for (uint256 v; v < VAULTS; ++v) {
            bool hasAssignments = registry.getVaultAccountsWithRoles(_vaults[v]).length > 0;
            assertEq(_contains(list, _vaults[v]), hasAssignments, "vault listed <=> has assignments");
        }
    }

    function _assertAccountVaults(uint256 a_) private view {
        address[] memory list = registry.getAccountVaults(accounts[a_]);
        uint256 expected;
        for (uint256 v; v < VAULTS; ++v) {
            bool any;
            for (uint256 r; r < ROLES; ++r) {
                if (_has[v][a_][r]) any = true;
            }
            assertEq(_contains(list, _vaults[v]), any, "accountVaults <=> any role");
            if (any) ++expected;
        }
        assertEq(list.length, expected, "accountVaults length");
        assertEq(registry.getAccountVaultsCount(accounts[a_]), list.length, "accountVaults count");
    }

    function _assertPage(address[] memory full_, address[] memory page_, uint256 offset_, uint256 limit_) private pure {
        if (offset_ >= full_.length || limit_ == 0) {
            assertEq(page_.length, 0, "page must be empty");
            return;
        }
        uint256 remaining = full_.length - offset_;
        uint256 expected = limit_ < remaining ? limit_ : remaining;
        assertEq(page_.length, expected, "page length");
        for (uint256 i; i < expected; ++i) {
            assertEq(page_[i], full_[offset_ + i], "page item");
        }
    }

    /// @dev Pages of `pageSize_` concatenated must equal the full list position by position (account and roleIds).
    function _assertAccountRolesPages(address vault_, uint256 pageSize_, AccountRoles[] memory full_) private view {
        uint256 position;
        for (uint256 offset; offset < full_.length; offset += pageSize_) {
            AccountRoles[] memory page = registry.getVaultAccountsWithRolesPaginated(vault_, offset, pageSize_);
            uint256 remaining = full_.length - offset;
            assertEq(page.length, pageSize_ < remaining ? pageSize_ : remaining, "account page length");
            for (uint256 i; i < page.length; ++i) {
                _assertAccountRolesItem(page[i], full_[position], "account page item");
                ++position;
            }
        }
        assertEq(position, full_.length, "account pages cover the full list");
        assertEq(registry.getVaultAccountsWithRolesPaginated(vault_, full_.length, 1).length, 0, "offset == count");
    }

    function _assertAccountRolesPage(
        AccountRoles[] memory full_,
        AccountRoles[] memory page_,
        uint256 offset_,
        uint256 limit_
    ) private pure {
        if (offset_ >= full_.length || limit_ == 0) {
            assertEq(page_.length, 0, "account page must be empty");
            return;
        }
        uint256 remaining = full_.length - offset_;
        uint256 expected = limit_ < remaining ? limit_ : remaining;
        assertEq(page_.length, expected, "account page length");
        for (uint256 i; i < expected; ++i) {
            _assertAccountRolesItem(page_[i], full_[offset_ + i], "account page item");
        }
    }

    function _assertAccountRolesEqual(
        AccountRoles[] memory actual_,
        AccountRoles[] memory expected_,
        string memory message_
    ) private pure {
        assertEq(actual_.length, expected_.length, message_);
        for (uint256 i; i < actual_.length; ++i) {
            _assertAccountRolesItem(actual_[i], expected_[i], message_);
        }
    }

    function _assertAccountRolesItem(
        AccountRoles memory actual_,
        AccountRoles memory expected_,
        string memory message_
    ) private pure {
        assertEq(actual_.account, expected_.account, message_);
        assertEq(actual_.roleIds.length, expected_.roleIds.length, message_);
        for (uint256 j; j < actual_.roleIds.length; ++j) {
            assertEq(actual_.roleIds[j], expected_.roleIds[j], message_);
        }
    }

    // ------------------------------------------------------------------ helpers

    function _accountIndex(address account_) private view returns (uint256) {
        for (uint256 a; a < ACCOUNTS; ++a) {
            if (accounts[a] == account_) return a;
        }
        revert UnknownRegistryAccount(account_);
    }

    function _contains(address[] memory list_, address item_) private pure returns (bool) {
        for (uint256 i; i < list_.length; ++i) {
            if (list_[i] == item_) return true;
        }
        return false;
    }

    function _contains(bytes32[] memory list_, bytes32 item_) private pure returns (bool) {
        for (uint256 i; i < list_.length; ++i) {
            if (list_[i] == item_) return true;
        }
        return false;
    }
}
