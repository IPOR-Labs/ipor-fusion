// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PlasmaVaultPauser} from "../../contracts/managers/pause/PlasmaVaultPauser.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {IIporFusionAccessManager} from "../../contracts/interfaces/IIporFusionAccessManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";

/// @dev Minimal vault mock exposing the AccessManaged authority() getter used by the pauser
contract MockAccessManagedVault {
    address private _authority;

    constructor(address authority_) {
        _authority = authority_;
    }

    function authority() external view returns (address) {
        return _authority;
    }

    function setAuthority(address authority_) external {
        _authority = authority_;
    }
}

/// @dev Access manager mock recording updateTargetClosed calls
contract MockAccessManager {
    address public lastTarget;
    bool public lastClosed;
    uint256 public updateTargetClosedCallCount;

    mapping(address target => bool closed) public closedTargets;

    function updateTargetClosed(address target_, bool closed_) external {
        lastTarget = target_;
        lastClosed = closed_;
        updateTargetClosedCallCount++;
        closedTargets[target_] = closed_;
    }

    function isTargetClosed(address target_) external view returns (bool) {
        return closedTargets[target_];
    }
}

/// @dev Access manager mock which accepts updateTargetClosed but never closes the target
contract MockSilentAccessManager {
    function updateTargetClosed(address target_, bool closed_) external {
        // intentionally does not close the target
    }

    function isTargetClosed(address) external pure returns (bool) {
        return false;
    }
}

contract PlasmaVaultPauserTest is Test {
    PlasmaVaultPauser internal pauser;
    MockAccessManager internal accessManager;
    MockAccessManagedVault internal vault;
    MockAccessManagedVault internal vaultB;

    address internal owner;
    address internal newOwner;
    address internal guardian;
    address internal user;

    function setUp() public {
        owner = makeAddr("owner");
        newOwner = makeAddr("newOwner");
        guardian = makeAddr("guardian");
        user = makeAddr("user");

        pauser = new PlasmaVaultPauser(owner);

        accessManager = new MockAccessManager();
        vault = new MockAccessManagedVault(address(accessManager));
        vaultB = new MockAccessManagedVault(address(accessManager));
    }

    //
    // Ownership - Ownable2Step
    //

    function testShouldSetProvidedAddressAsOwner() public {
        // then - setUp deployed the pauser with the owner address provided explicitly
        assertEq(pauser.owner(), owner, "provided address should be the owner");
        assertEq(pauser.pendingOwner(), address(0), "pending owner should be empty");
    }

    function testShouldSetDeployerAsOwnerWhenZeroAddressProvided() public {
        // when
        vm.prank(user);
        PlasmaVaultPauser newPauser = new PlasmaVaultPauser(address(0));

        // then
        assertEq(newPauser.owner(), user, "deployer should be the owner when zero address is provided");
    }

    function testShouldStartTwoStepOwnershipTransfer() public {
        // when
        vm.expectEmit(true, true, true, true);
        emit Ownable2Step.OwnershipTransferStarted(owner, newOwner);
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // then
        assertEq(pauser.owner(), owner, "owner should not change before acceptance");
        assertEq(pauser.pendingOwner(), newOwner, "pending owner should be set");
    }

    function testShouldCompleteTwoStepOwnershipTransfer() public {
        // given
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // when
        vm.expectEmit(true, true, true, true);
        emit Ownable.OwnershipTransferred(owner, newOwner);
        vm.prank(newOwner);
        pauser.acceptOwnership();

        // then
        assertEq(pauser.owner(), newOwner, "new owner should be set after acceptance");
        assertEq(pauser.pendingOwner(), address(0), "pending owner should be cleared");
    }

    function testShouldNotTransferOwnershipWhenNotOwner() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        pauser.transferOwnership(newOwner);
    }

    function testShouldNotAcceptOwnershipWhenNotPendingOwner() public {
        // given
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        pauser.acceptOwnership();
    }

    function testShouldOverridePendingOwnerBeforeAcceptance() public {
        // given
        address anotherOwner = makeAddr("anotherOwner");
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // when
        vm.prank(owner);
        pauser.transferOwnership(anotherOwner);

        // then - the first pending owner cannot accept anymore
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        pauser.acceptOwnership();

        vm.prank(anotherOwner);
        pauser.acceptOwnership();
        assertEq(pauser.owner(), anotherOwner, "second pending owner should become the owner");
    }

    function testShouldCancelOwnershipTransferBySettingPendingOwnerToZero() public {
        // given
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // when
        vm.prank(owner);
        pauser.transferOwnership(address(0));

        // then
        assertEq(pauser.pendingOwner(), address(0), "pending owner should be cleared");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        pauser.acceptOwnership();
        assertEq(pauser.owner(), owner, "owner should not change");
    }

    function testShouldKeepOwnerRightsUntilTransferAccepted() public {
        // given
        vm.prank(owner);
        pauser.transferOwnership(newOwner);

        // when - current owner still manages the whitelist
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertTrue(pauser.isWhitelisted(address(vault), guardian), "owner should still manage the whitelist");

        // and - pending owner has no rights yet
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        vm.prank(newOwner);
        pauser.addToWhitelist(address(vault), user);
    }

    function testShouldNewOwnerManageWhitelistAfterTransfer() public {
        // given
        vm.prank(owner);
        pauser.transferOwnership(newOwner);
        vm.prank(newOwner);
        pauser.acceptOwnership();

        // when
        vm.prank(newOwner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertTrue(pauser.isWhitelisted(address(vault), guardian), "new owner should manage the whitelist");

        // and - previous owner lost the rights
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), user);
    }

    function testShouldNotRenounceOwnership() public {
        // when / then
        vm.expectRevert(PlasmaVaultPauser.RenounceOwnershipDisabled.selector);
        vm.prank(owner);
        pauser.renounceOwnership();

        assertEq(pauser.owner(), owner, "owner should not change");
    }

    function testShouldNotRenounceOwnershipWhenNotOwner() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        pauser.renounceOwnership();
    }

    //
    // Whitelist management
    //

    function testShouldAddToWhitelist() public {
        // when
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.AddressAddedToWhitelist(address(vault), guardian);
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertTrue(pauser.isWhitelisted(address(vault), guardian), "account should be whitelisted");
    }

    function testShouldRemoveFromWhitelist() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.AddressRemovedFromWhitelist(address(vault), guardian);
        vm.prank(owner);
        pauser.removeFromWhitelist(address(vault), guardian);

        // then
        assertFalse(pauser.isWhitelisted(address(vault), guardian), "account should not be whitelisted");
    }

    function testShouldNotAddToWhitelistWhenNotOwner() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        pauser.addToWhitelist(address(vault), guardian);

        assertFalse(pauser.isWhitelisted(address(vault), guardian), "account should not be whitelisted");
    }

    function testShouldNotRemoveFromWhitelistWhenNotOwner() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        pauser.removeFromWhitelist(address(vault), guardian);

        assertTrue(pauser.isWhitelisted(address(vault), guardian), "account should stay whitelisted");
    }

    function testShouldNotAddToWhitelistWhenVaultZeroAddress() public {
        // when / then
        vm.expectRevert(Errors.WrongAddress.selector);
        vm.prank(owner);
        pauser.addToWhitelist(address(0), guardian);
    }

    function testShouldNotAddToWhitelistWhenAccountZeroAddress() public {
        // when / then
        vm.expectRevert(Errors.WrongAddress.selector);
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), address(0));
    }

    function testShouldNotEmitEventWhenAddingAlreadyWhitelistedAccount() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when
        vm.recordLogs();
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event should be emitted on redundant add");
        assertTrue(pauser.isWhitelisted(address(vault), guardian), "account should stay whitelisted");
        assertEq(pauser.getWhitelistedAccounts(address(vault)).length, 1, "accounts set should have no duplicates");
        assertEq(pauser.getWhitelistedVaults(guardian).length, 1, "vaults set should have no duplicates");
        assertEq(pauser.getVaultsCount(), 1, "global vaults list should have no duplicates");
        assertEq(pauser.getAccountsCount(), 1, "global accounts list should have no duplicates");
    }

    function testShouldNotEmitEventWhenRemovingNotWhitelistedAccount() public {
        // when
        vm.recordLogs();
        vm.prank(owner);
        pauser.removeFromWhitelist(address(vault), guardian);

        // then
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no event should be emitted on redundant remove");
        assertFalse(pauser.isWhitelisted(address(vault), guardian), "account should not be whitelisted");
    }

    function testShouldWhitelistBeScopedPerVault() public {
        // when
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertTrue(pauser.isWhitelisted(address(vault), guardian), "account should be whitelisted for vault");
        assertFalse(pauser.isWhitelisted(address(vaultB), guardian), "account should not be whitelisted for vaultB");
    }

    //
    // Whitelist enumeration
    //

    function testShouldListWhitelistedAccountsForVault() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vault), user);
        pauser.addToWhitelist(address(vaultB), guardian);
        vm.stopPrank();

        // when
        address[] memory vaultAccounts = pauser.getWhitelistedAccounts(address(vault));
        address[] memory vaultBAccounts = pauser.getWhitelistedAccounts(address(vaultB));

        // then
        assertEq(vaultAccounts.length, 2, "vault should have two whitelisted accounts");
        assertEq(vaultAccounts[0], guardian, "first whitelisted account should be listed");
        assertEq(vaultAccounts[1], user, "second whitelisted account should be listed");
        assertEq(vaultBAccounts.length, 1, "vaultB should have one whitelisted account");
        assertEq(vaultBAccounts[0], guardian, "vaultB whitelisted account should be listed");
    }

    function testShouldListWhitelistedVaultsForAccount() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vaultB), guardian);
        vm.stopPrank();

        // when
        address[] memory guardianVaults = pauser.getWhitelistedVaults(guardian);

        // then
        assertEq(guardianVaults.length, 2, "guardian should have two vaults");
        assertEq(guardianVaults[0], address(vault), "first vault should be listed");
        assertEq(guardianVaults[1], address(vaultB), "second vault should be listed");
        assertEq(pauser.getWhitelistedVaults(user).length, 0, "user should have no vaults");
    }

    function testShouldKeepBothWhitelistSidesInSyncAfterRemoval() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vault), user);
        pauser.addToWhitelist(address(vaultB), guardian);

        // when
        pauser.removeFromWhitelist(address(vault), guardian);
        vm.stopPrank();

        // then
        address[] memory vaultAccounts = pauser.getWhitelistedAccounts(address(vault));
        assertEq(vaultAccounts.length, 1, "vault should have one whitelisted account left");
        assertEq(vaultAccounts[0], user, "remaining whitelisted account should be listed");

        address[] memory guardianVaults = pauser.getWhitelistedVaults(guardian);
        assertEq(guardianVaults.length, 1, "guardian should have one vault left");
        assertEq(guardianVaults[0], address(vaultB), "remaining vault should be listed");
    }

    function testShouldReturnEmptyListsWhenNothingWhitelisted() public {
        // then
        assertEq(pauser.getWhitelistedAccounts(address(vault)).length, 0, "accounts list should be empty");
        assertEq(pauser.getWhitelistedVaults(guardian).length, 0, "vaults list should be empty");
    }

    function testShouldReturnWhitelistCounts() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vault), user);
        pauser.addToWhitelist(address(vaultB), guardian);
        vm.stopPrank();

        // then
        assertEq(pauser.getWhitelistedAccountsCount(address(vault)), 2, "vault should have two whitelisted accounts");
        assertEq(pauser.getWhitelistedAccountsCount(address(vaultB)), 1, "vaultB should have one whitelisted account");
        assertEq(pauser.getWhitelistedVaultsCount(guardian), 2, "guardian should have two vaults");
        assertEq(pauser.getWhitelistedVaultsCount(user), 1, "user should have one vault");
        assertEq(pauser.getWhitelistedAccountsCount(makeAddr("unknownVault")), 0, "unknown vault should be empty");
        assertEq(pauser.getWhitelistedVaultsCount(makeAddr("unknownAccount")), 0, "unknown account should be empty");
    }

    function testShouldPaginateWhitelistedAccounts() public {
        // given - five accounts whitelisted for the vault
        address[] memory accounts = new address[](5);
        vm.startPrank(owner);
        for (uint256 i; i < accounts.length; ++i) {
            accounts[i] = makeAddr(string.concat("account", vm.toString(i)));
            pauser.addToWhitelist(address(vault), accounts[i]);
        }
        vm.stopPrank();

        // when - reading in pages of two
        address[] memory pageOne = pauser.getWhitelistedAccounts(address(vault), 0, 2);
        address[] memory pageTwo = pauser.getWhitelistedAccounts(address(vault), 2, 2);
        address[] memory pageThree = pauser.getWhitelistedAccounts(address(vault), 4, 2);

        // then - pages concatenate to the full list
        address[] memory all = pauser.getWhitelistedAccounts(address(vault));
        assertEq(all.length, 5, "full list should have five entries");
        assertEq(pageOne.length, 2, "first page should have two entries");
        assertEq(pageTwo.length, 2, "second page should have two entries");
        assertEq(pageThree.length, 1, "last page should be truncated to the remaining entry");
        assertEq(pageOne[0], all[0], "page element should match the full list");
        assertEq(pageOne[1], all[1], "page element should match the full list");
        assertEq(pageTwo[0], all[2], "page element should match the full list");
        assertEq(pageTwo[1], all[3], "page element should match the full list");
        assertEq(pageThree[0], all[4], "page element should match the full list");
    }

    function testShouldPaginateWhitelistedVaults() public {
        // given - guardian whitelisted for three vaults
        address[] memory vaults = new address[](3);
        vm.startPrank(owner);
        for (uint256 i; i < vaults.length; ++i) {
            vaults[i] = makeAddr(string.concat("vault", vm.toString(i)));
            pauser.addToWhitelist(vaults[i], guardian);
        }
        vm.stopPrank();

        // when
        address[] memory pageOne = pauser.getWhitelistedVaults(guardian, 0, 2);
        address[] memory pageTwo = pauser.getWhitelistedVaults(guardian, 2, 2);

        // then
        address[] memory all = pauser.getWhitelistedVaults(guardian);
        assertEq(all.length, 3, "full list should have three entries");
        assertEq(pageOne.length, 2, "first page should have two entries");
        assertEq(pageTwo.length, 1, "second page should be truncated to the remaining entry");
        assertEq(pageOne[0], all[0], "page element should match the full list");
        assertEq(pageOne[1], all[1], "page element should match the full list");
        assertEq(pageTwo[0], all[2], "page element should match the full list");
    }

    function testShouldReturnEmptyPageWhenOffsetOutOfRange() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertEq(pauser.getWhitelistedAccounts(address(vault), 1, 10).length, 0, "offset equal to length");
        assertEq(pauser.getWhitelistedAccounts(address(vault), 100, 10).length, 0, "offset above length");
        assertEq(pauser.getWhitelistedVaults(guardian, 1, 10).length, 0, "offset equal to length");
        assertEq(pauser.getWhitelistedVaults(guardian, 100, 10).length, 0, "offset above length");
    }

    function testShouldReturnEmptyPageWhenLimitIsZero() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // then
        assertEq(pauser.getWhitelistedAccounts(address(vault), 0, 0).length, 0, "zero limit should return empty page");
        assertEq(pauser.getWhitelistedVaults(guardian, 0, 0).length, 0, "zero limit should return empty page");
    }

    function testShouldListAllConfiguredVaultsAndAccounts() public {
        // given - empty at start
        assertEq(pauser.getVaultsCount(), 0, "no vaults should be configured initially");
        assertEq(pauser.getAccountsCount(), 0, "no accounts should be configured initially");

        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vault), user);
        pauser.addToWhitelist(address(vaultB), guardian);
        vm.stopPrank();

        // when
        address[] memory allVaults = pauser.getVaults();
        address[] memory allAccounts = pauser.getAccounts();

        // then - every configured vault and account listed exactly once
        assertEq(allVaults.length, 2, "two vaults should be configured");
        assertEq(allVaults[0], address(vault), "vault should be listed");
        assertEq(allVaults[1], address(vaultB), "vaultB should be listed");
        assertEq(allAccounts.length, 2, "two accounts should be configured");
        assertEq(allAccounts[0], guardian, "guardian should be listed once despite two vaults");
        assertEq(allAccounts[1], user, "user should be listed");
        assertEq(pauser.getVaultsCount(), 2, "vaults count should match the list");
        assertEq(pauser.getAccountsCount(), 2, "accounts count should match the list");
    }

    function testShouldRemoveVaultFromGlobalListWhenLastAccountRemoved() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vault), user);

        // when - one account removed, the vault stays configured
        pauser.removeFromWhitelist(address(vault), guardian);
        assertEq(pauser.getVaultsCount(), 1, "vault should stay configured while one account is left");

        // and - the last account removed
        pauser.removeFromWhitelist(address(vault), user);
        vm.stopPrank();

        // then
        assertEq(pauser.getVaultsCount(), 0, "vault should be removed together with its last account");
        assertEq(pauser.getVaults().length, 0, "vaults list should be empty");
        assertEq(pauser.getAccountsCount(), 0, "accounts list should be empty as well");
    }

    function testShouldRemoveAccountFromGlobalListWhenLastVaultRemoved() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.addToWhitelist(address(vaultB), guardian);

        // when - guardian removed from one vault, still configured for the other
        pauser.removeFromWhitelist(address(vault), guardian);
        assertEq(pauser.getAccountsCount(), 1, "account should stay configured while one vault is left");

        // and - removed from the last vault
        pauser.removeFromWhitelist(address(vaultB), guardian);
        vm.stopPrank();

        // then
        assertEq(pauser.getAccountsCount(), 0, "account should be removed together with its last vault");
        assertEq(pauser.getAccounts().length, 0, "accounts list should be empty");
        assertEq(pauser.getVaultsCount(), 0, "vaults list should be empty as well");
    }

    function testShouldPaginateGlobalVaultsAndAccountsLists() public {
        // given - three vaults each with a distinct account
        vm.startPrank(owner);
        for (uint256 i; i < 3; ++i) {
            pauser.addToWhitelist(
                makeAddr(string.concat("vault", vm.toString(i))),
                makeAddr(string.concat("account", vm.toString(i)))
            );
        }
        vm.stopPrank();

        // when
        address[] memory vaultsPageOne = pauser.getVaults(0, 2);
        address[] memory vaultsPageTwo = pauser.getVaults(2, 2);
        address[] memory accountsPageOne = pauser.getAccounts(0, 2);
        address[] memory accountsPageTwo = pauser.getAccounts(2, 2);

        // then
        address[] memory allVaults = pauser.getVaults();
        address[] memory allAccounts = pauser.getAccounts();
        assertEq(vaultsPageOne.length, 2, "first vaults page should have two entries");
        assertEq(vaultsPageTwo.length, 1, "second vaults page should be truncated");
        assertEq(vaultsPageOne[0], allVaults[0], "page element should match the full list");
        assertEq(vaultsPageOne[1], allVaults[1], "page element should match the full list");
        assertEq(vaultsPageTwo[0], allVaults[2], "page element should match the full list");
        assertEq(accountsPageOne.length, 2, "first accounts page should have two entries");
        assertEq(accountsPageTwo.length, 1, "second accounts page should be truncated");
        assertEq(accountsPageOne[0], allAccounts[0], "page element should match the full list");
        assertEq(accountsPageOne[1], allAccounts[1], "page element should match the full list");
        assertEq(accountsPageTwo[0], allAccounts[2], "page element should match the full list");
    }

    function testFuzzShouldPaginateConsistentlyWithFullList(uint256 count_, uint256 offset_, uint256 limit_) public {
        // given
        count_ = bound(count_, 0, 8);
        offset_ = bound(offset_, 0, 10);
        limit_ = bound(limit_, 0, 10);

        vm.startPrank(owner);
        for (uint256 i; i < count_; ++i) {
            pauser.addToWhitelist(address(vault), makeAddr(string.concat("account", vm.toString(i))));
        }
        vm.stopPrank();

        // when
        address[] memory page = pauser.getWhitelistedAccounts(address(vault), offset_, limit_);
        address[] memory all = pauser.getWhitelistedAccounts(address(vault));

        // then
        uint256 remaining = offset_ >= count_ ? 0 : count_ - offset_;
        uint256 expectedSize = remaining < limit_ ? remaining : limit_;
        assertEq(page.length, expectedSize, "page size should match expected");
        for (uint256 i; i < page.length; ++i) {
            assertEq(page[i], all[offset_ + i], "page element should match the full list");
        }
    }

    //
    // Pause
    //

    function testShouldPauseVaultWhenWhitelisted() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.VaultPaused(address(vault), address(accessManager), guardian);
        vm.prank(guardian);
        pauser.pause(address(vault));

        // then
        assertEq(accessManager.lastTarget(), address(vault), "updateTargetClosed should be called with the vault");
        assertTrue(accessManager.lastClosed(), "updateTargetClosed should be called with closed = true");
        assertEq(accessManager.updateTargetClosedCallCount(), 1, "updateTargetClosed should be called once");
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault should be closed");
    }

    function testShouldPauseAgainWhenAlreadyPaused() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        vm.prank(guardian);
        pauser.pause(address(vault));

        // when
        vm.prank(guardian);
        pauser.pause(address(vault));

        // then
        assertEq(accessManager.updateTargetClosedCallCount(), 2, "updateTargetClosed should be called twice");
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault should stay closed");
    }

    function testShouldNotPauseWhenNotWhitelisted() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, address(vault), user));
        vm.prank(user);
        pauser.pause(address(vault));

        assertEq(accessManager.updateTargetClosedCallCount(), 0, "updateTargetClosed should not be called");
    }

    function testShouldNotPauseWhenOwnerNotWhitelisted() public {
        // when / then - the owner has no implicit right to pause
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, address(vault), owner)
        );
        vm.prank(owner);
        pauser.pause(address(vault));
    }

    function testShouldNotPauseOtherVaultThanWhitelistedFor() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, address(vaultB), guardian)
        );
        vm.prank(guardian);
        pauser.pause(address(vaultB));

        assertEq(accessManager.updateTargetClosedCallCount(), 0, "updateTargetClosed should not be called");
    }

    function testShouldNotPauseAfterRemovalFromWhitelist() public {
        // given
        vm.startPrank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        pauser.removeFromWhitelist(address(vault), guardian);
        vm.stopPrank();

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, address(vault), guardian)
        );
        vm.prank(guardian);
        pauser.pause(address(vault));
    }

    function testShouldNotPauseWhenAuthorityIsZeroAddress() public {
        // given
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);
        vault.setAuthority(address(0));

        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultPauser.InvalidAuthority.selector, address(vault)));
        vm.prank(guardian);
        pauser.pause(address(vault));
    }

    function testShouldNotPauseWhenAccessManagerDoesNotCloseVault() public {
        // given
        MockSilentAccessManager silentAccessManager = new MockSilentAccessManager();
        vault.setAuthority(address(silentAccessManager));
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultPauser.VaultPauseFailed.selector, address(vault)));
        vm.prank(guardian);
        pauser.pause(address(vault));
    }

    function testShouldNotPauseWhenVaultIsNotAContract() public {
        // given
        address eoaVault = makeAddr("eoaVault");
        vm.prank(owner);
        pauser.addToWhitelist(eoaVault, guardian);

        // when / then
        vm.expectRevert();
        vm.prank(guardian);
        pauser.pause(eoaVault);
    }

    //
    // Fuzz
    //

    function testFuzzShouldNotPauseWhenCallerNotWhitelisted(address caller_) public {
        // given
        vm.assume(caller_ != guardian);
        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, address(vault), caller_)
        );
        vm.prank(caller_);
        pauser.pause(address(vault));
    }

    function testFuzzShouldManageWhitelistForAnyVaultAndAccount(address vault_, address account_) public {
        // given
        vm.assume(vault_ != address(0));
        vm.assume(account_ != address(0));

        // when / then
        vm.startPrank(owner);
        pauser.addToWhitelist(vault_, account_);
        assertTrue(pauser.isWhitelisted(vault_, account_), "account should be whitelisted");
        assertEq(pauser.getWhitelistedAccounts(vault_).length, 1, "accounts list should have one entry");
        assertEq(pauser.getWhitelistedVaults(account_).length, 1, "vaults list should have one entry");
        assertEq(pauser.getVaultsCount(), 1, "global vaults list should have one entry");
        assertEq(pauser.getAccountsCount(), 1, "global accounts list should have one entry");

        pauser.removeFromWhitelist(vault_, account_);
        assertFalse(pauser.isWhitelisted(vault_, account_), "account should not be whitelisted");
        assertEq(pauser.getWhitelistedAccounts(vault_).length, 0, "accounts list should be empty");
        assertEq(pauser.getWhitelistedVaults(account_).length, 0, "vaults list should be empty");
        assertEq(pauser.getVaultsCount(), 0, "global vaults list should be empty");
        assertEq(pauser.getAccountsCount(), 0, "global accounts list should be empty");
        vm.stopPrank();
    }
}

contract PlasmaVaultPauserIntegrationTest is Test {
    PlasmaVaultPauser internal pauser;
    IporFusionAccessManager internal accessManager;
    MockAccessManagedVault internal vault;

    address internal admin;
    address internal owner;
    address internal guardian;
    address internal user;

    bytes4 internal constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(uint256,address)"));

    function setUp() public {
        admin = makeAddr("admin");
        owner = makeAddr("owner");
        guardian = makeAddr("guardian");
        user = makeAddr("user");

        accessManager = new IporFusionAccessManager(admin, 0);
        vault = new MockAccessManagedVault(address(accessManager));

        pauser = new PlasmaVaultPauser(owner);

        bytes4[] memory updateTargetClosedSelectors = new bytes4[](1);
        updateTargetClosedSelectors[0] = IIporFusionAccessManager.updateTargetClosed.selector;

        bytes4[] memory depositSelectors = new bytes4[](1);
        depositSelectors[0] = DEPOSIT_SELECTOR;

        vm.startPrank(admin);
        accessManager.setTargetFunctionRole(address(accessManager), updateTargetClosedSelectors, Roles.GUARDIAN_ROLE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, address(pauser), 0);
        /// @dev simulate a public vault function to observe the effect of closing the target
        accessManager.setTargetFunctionRole(address(vault), depositSelectors, Roles.PUBLIC_ROLE);
        vm.stopPrank();

        vm.prank(owner);
        pauser.addToWhitelist(address(vault), guardian);
    }

    function testShouldPauseVaultOnRealAccessManager() public {
        // given
        assertFalse(accessManager.isTargetClosed(address(vault)), "vault should be open before pause");
        (bool immediateBefore, ) = accessManager.canCall(user, address(vault), DEPOSIT_SELECTOR);
        assertTrue(immediateBefore, "public vault function should be callable before pause");

        // when
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.VaultPaused(address(vault), address(accessManager), guardian);
        vm.prank(guardian);
        pauser.pause(address(vault));

        // then
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault should be closed after pause");
        (bool immediateAfter, uint32 delayAfter) = accessManager.canCall(user, address(vault), DEPOSIT_SELECTOR);
        assertFalse(immediateAfter, "vault functions should be blocked after pause");
        assertEq(delayAfter, 0, "no delayed execution should be possible on a closed target");
    }

    function testShouldPauseBeIdempotentOnRealAccessManager() public {
        // when
        vm.startPrank(guardian);
        pauser.pause(address(vault));
        pauser.pause(address(vault));
        vm.stopPrank();

        // then
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault should stay closed");
    }

    function testShouldNotPauseWhenPauserContractHasNoGuardianRole() public {
        // given - a pauser which was never granted GUARDIAN_ROLE on the access manager
        vm.startPrank(owner);
        PlasmaVaultPauser pauserWithoutRole = new PlasmaVaultPauser(owner);
        pauserWithoutRole.addToWhitelist(address(vault), guardian);
        vm.stopPrank();

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                IporFusionAccessManager.AccessManagedUnauthorized.selector,
                address(pauserWithoutRole)
            )
        );
        vm.prank(guardian);
        pauserWithoutRole.pause(address(vault));

        assertFalse(accessManager.isTargetClosed(address(vault)), "vault should stay open");
    }

    function testShouldNotWhitelistedAccountCallAccessManagerDirectly() public {
        // when / then - the whitelisted account has no GUARDIAN_ROLE, only the pauser contract has it
        vm.expectRevert(abi.encodeWithSelector(IporFusionAccessManager.AccessManagedUnauthorized.selector, guardian));
        vm.prank(guardian);
        accessManager.updateTargetClosed(address(vault), true);
    }

    function testShouldGuardianReopenVaultPausedByPauser() public {
        // given
        vm.prank(guardian);
        pauser.pause(address(vault));
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault should be closed after pause");

        address humanGuardian = makeAddr("humanGuardian");
        vm.prank(admin);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, humanGuardian, 0);

        // when - reopening happens directly on the access manager, the pauser cannot do it
        vm.prank(humanGuardian);
        accessManager.updateTargetClosed(address(vault), false);

        // then
        assertFalse(accessManager.isTargetClosed(address(vault)), "vault should be reopened by the guardian");
    }
}
