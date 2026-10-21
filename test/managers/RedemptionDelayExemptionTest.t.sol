// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {
    IporFusionAccessManagerInitializerLibV1,
    DataForInitialization,
    PlasmaVaultAddress
} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";

/// @notice Unit tests of the redemption delay exemptions on the access manager: exit semantics, setter, getters,
/// storage namespace and the gas shape of the exit check.
/// @dev The PLASMA_VAULT address plays the vault (TECH_PLASMA_VAULT_ROLE) and calls the setter directly, exactly like
/// setRedemptionDelay in RedemptionDelayUpdateTest. Vault-level behaviour lives in RedemptionDelayExemptionVaultTest.
contract RedemptionDelayExemptionTest is Test {
    uint256 private constant INITIAL_REDEMPTION_DELAY = 1 days;
    uint256 private constant BASE_TIMESTAMP = 1_700_000_000;

    /// @dev Account holding TECH_PLASMA_VAULT_ROLE, simulates the PlasmaVault calling canCallAndUpdate
    address private constant PLASMA_VAULT = address(0x999);

    address private admin = address(0x1);
    address private owner = address(0x2);
    address private atomist = address(0x3);
    address private userOne = address(0x777);
    address private userTwo = address(0x888);
    address private userThree = address(0x555);

    IporFusionAccessManager private accessManager;

    /// @dev ERC-7201 slot of io.ipor.managers.access.RedemptionDelayExemptions: AddressSet at this slot,
    /// `_values` array length at S, `_positions` mapping at S + 1 (OpenZeppelin 5.0.2 EnumerableSet layout)
    bytes32 private constant EXEMPTIONS_SLOT = 0xc907ff1647cc23a1ed16a70292ca2dd8b68ec279b648a0a2e9599d2834e88f00;
    /// @dev ERC-7201 slot of io.ipor.managers.access.RedemptionLockStartTimes (mapping account => lock start)
    bytes32 private constant LOCK_START_TIMES_SLOT = 0x83e7bafd2a5059a7a3f8f00883c599ce24355cc422725b4bf7e796d03c954a00;
    uint256 private constant CUSTOM_CONSUMING_SCHEDULE_SLOT = 4;
    /// @dev Cost of one cold SLOAD, the upper bound of what the exemption check may add to an exit
    uint256 private constant COLD_SLOAD_GAS = 2_600;

    event RedemptionDelayExemptionUpdated(address account, bool exempt);
    event RedemptionDelayForAccountUpdated(address account, uint256 lockStartTime, uint256 unlockTime);

    function setUp() public {
        vm.warp(BASE_TIMESTAMP);
        accessManager = new IporFusionAccessManager(admin, INITIAL_REDEMPTION_DELAY);
        vm.prank(admin);
        accessManager.initialize(_generateInitializationData());
    }

    // ---------------------------------------------------------------- setter

    function testShouldAddExemptionsInBatchAndEmitEventPerAccount() public {
        //given
        address[] memory accounts = _accounts(userOne, userTwo, userThree);

        //when
        for (uint256 i; i < accounts.length; i++) {
            vm.expectEmit(address(accessManager));
            emit RedemptionDelayExemptionUpdated(accounts[i], true);
        }
        _setExemption(accounts, true);

        //then
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 3);
        assertEq(accessManager.getRedemptionDelayExemptions(), accounts);
        assertTrue(accessManager.isRedemptionDelayExempt(userOne));
        assertTrue(accessManager.isRedemptionDelayExempt(userTwo));
        assertTrue(accessManager.isRedemptionDelayExempt(userThree));
    }

    function testShouldRemoveExemptionsInBatchAndEmitEventPerAccount() public {
        //given
        _setExemption(_accounts(userOne, userTwo, userThree), true);
        address[] memory toRemove = _accounts(userOne, userThree);

        //when
        for (uint256 i; i < toRemove.length; i++) {
            vm.expectEmit(address(accessManager));
            emit RedemptionDelayExemptionUpdated(toRemove[i], false);
        }
        _setExemption(toRemove, false);

        //then
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 1);
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userTwo));
        assertFalse(accessManager.isRedemptionDelayExempt(userOne));
        assertTrue(accessManager.isRedemptionDelayExempt(userTwo));
        assertFalse(accessManager.isRedemptionDelayExempt(userThree));
    }

    function testShouldEmitEventEvenWhenExemptionStateDoesNotChange() public {
        //given
        _setExemption(_accounts(userOne), true);

        //when: re-adding an exempt address emits again
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(userOne, true);
        _setExemption(_accounts(userOne), true);

        //when: removing a never listed address emits too
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(userTwo, false);
        _setExemption(_accounts(userTwo), false);

        //when: a duplicate inside one batch emits for each occurrence
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(userThree, true);
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayExemptionUpdated(userThree, true);
        _setExemption(_accounts(userThree, userThree), true);

        //then: state is as if each address was added once / never
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);
        assertTrue(accessManager.isRedemptionDelayExempt(userOne));
        assertFalse(accessManager.isRedemptionDelayExempt(userTwo));
        assertTrue(accessManager.isRedemptionDelayExempt(userThree));
    }

    function testShouldNotSetExemptionWhenNotPlasmaVault() public {
        //given
        address[] memory unauthorizedCallers = new address[](4);
        unauthorizedCallers[0] = owner;
        unauthorizedCallers[1] = atomist;
        unauthorizedCallers[2] = admin;
        unauthorizedCallers[3] = address(0xdead);
        address[] memory accounts = _accounts(userOne);

        for (uint256 i; i < unauthorizedCallers.length; i++) {
            //when/then: both directions are restricted
            vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", unauthorizedCallers[i]));
            vm.prank(unauthorizedCallers[i]);
            accessManager.setRedemptionDelayExemption(accounts, true);

            vm.expectRevert(abi.encodeWithSignature("AccessManagedUnauthorized(address)", unauthorizedCallers[i]));
            vm.prank(unauthorizedCallers[i]);
            accessManager.setRedemptionDelayExemption(accounts, false);
        }

        //then
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 0);
    }

    function testShouldRevertWhenExemptingZeroAddress() public {
        //given: an existing entry that must survive the failed batches
        _setExemption(_accounts(userThree), true);

        for (uint256 i; i < 2; i++) {
            bool exempt = i == 0;
            // @dev add pass: userOne is added before the zero address; remove pass: userThree (really exempt) is
            // removed before the zero address, so the rollback of a real removal is shown
            address[] memory accounts = exempt
                ? _accounts(userOne, address(0), userTwo)
                : _accounts(userThree, address(0));

            //when: low-level call to read the raw revert data
            vm.prank(PLASMA_VAULT);
            (bool success, bytes memory returndata) = address(accessManager).call(
                abi.encodeCall(IporFusionAccessManager.setRedemptionDelayExemption, (accounts, exempt))
            );

            //then: reverted with WrongAddress, whole batch rolled back
            assertFalse(success, "must revert");
            assertEq(returndata, abi.encodeWithSignature("WrongAddress()"), "revert reason");
            // @dev Events of a reverted frame are discarded by the EVM; forge's vm.recordLogs would still list them,
            // so the rollback is proven through the state (processed-before-zero entries are not changed)
            assertEq(accessManager.getRedemptionDelayExemptionsCount(), 1, "count");
            assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userThree), "list unchanged");
            assertFalse(accessManager.isRedemptionDelayExempt(userOne), "userOne untouched");
            assertTrue(accessManager.isRedemptionDelayExempt(userThree), "existing entry untouched");
        }
    }

    function testShouldNotChangeAnythingForEmptyBatch() public {
        //given
        _setExemption(_accounts(userOne), true);
        address[] memory empty = new address[](0);
        vm.recordLogs();

        //when
        _setExemption(empty, true);
        _setExemption(empty, false);

        //then
        assertEq(vm.getRecordedLogs().length, 0, "no events");
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userOne));
    }

    // ------------------------------------------------------------- semantics

    function testShouldAllowExemptAccountAllFourGatedSelectorsRightAfterDeposit() public {
        //given
        _setExemption(_accounts(userOne), true);
        _deposit(userOne);
        assertEq(accessManager.getAccountLockTime(userOne), block.timestamp + INITIAL_REDEMPTION_DELAY);

        //when/then: same block, all four gated exits pass
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        _withdrawCheck(userOne, PlasmaVault.redeem.selector);
        _withdrawCheck(userOne, PlasmaVault.transfer.selector);
        _withdrawCheck(userOne, PlasmaVault.transferFrom.selector);
    }

    function testShouldStillLockNonExemptAccountUnderSameDelay() public {
        //given: another account is exempt, the depositor is not
        _setExemption(_accounts(userTwo), true);
        uint256 depositTs = block.timestamp;
        _deposit(userOne);

        bytes4[] memory selectors = _gatedSelectors();
        for (uint256 i; i < selectors.length; i++) {
            //when/then
            vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTs + INITIAL_REDEMPTION_DELAY));
            _withdrawCheck(userOne, selectors[i]);
        }
    }

    function testShouldExemptAccountThatDepositedBeforeBeingExempted() public {
        //given
        uint256 depositTs = block.timestamp;
        _deposit(userOne);
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTs + INITIAL_REDEMPTION_DELAY));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when: exempted afterwards, without a new deposit
        _setExemption(_accounts(userOne), true);

        //then
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        _withdrawCheck(userOne, PlasmaVault.redeem.selector);
        _withdrawCheck(userOne, PlasmaVault.transfer.selector);
        _withdrawCheck(userOne, PlasmaVault.transferFrom.selector);
    }

    function testShouldRelockRevokedAccountFromOriginalDeposit() public {
        //given
        uint256 depositTs = block.timestamp;
        _setExemption(_accounts(userOne), true);
        _deposit(userOne);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when
        _setExemption(_accounts(userOne), false);

        //then: locked again, measured from the original deposit
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTs + INITIAL_REDEMPTION_DELAY));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //then: one second early still locked, exactly at the unlock time it passes
        vm.warp(depositTs + INITIAL_REDEMPTION_DELAY - 1);
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTs + INITIAL_REDEMPTION_DELAY));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        vm.warp(depositTs + INITIAL_REDEMPTION_DELAY);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldRelockRevokedAccountFromOriginalDepositWithWarpsBetweenSteps() public {
        //given: deposit at t0
        uint256 depositTs = block.timestamp;
        _deposit(userOne);
        bytes32 lockStartSlot = keccak256(abi.encode(userOne, LOCK_START_TIMES_SLOT));

        //when: granted one hour later - the exit is allowed
        vm.warp(depositTs + 1 hours);
        _setExemption(_accounts(userOne), true);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);

        //when: revoked another hour later
        vm.warp(depositTs + 2 hours);
        _setExemption(_accounts(userOne), false);

        //then: locked until t0 + delay, not measured from the grant or the revoke
        vm.expectRevert(abi.encodeWithSignature("AccountIsLocked(uint256)", depositTs + INITIAL_REDEMPTION_DELAY));
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        assertEq(accessManager.getAccountLockTime(userOne), depositTs + INITIAL_REDEMPTION_DELAY, "lock time");
        assertEq(uint256(vm.load(address(accessManager), lockStartSlot)), depositTs, "lock start still t0");

        //then: passes exactly at t0 + delay
        vm.warp(depositTs + INITIAL_REDEMPTION_DELAY);
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
    }

    function testShouldStillRecordLockStartForExemptAccountOnDeposit() public {
        //given
        _setExemption(_accounts(userOne), true);

        //when
        vm.expectEmit(address(accessManager));
        emit RedemptionDelayForAccountUpdated(userOne, block.timestamp, block.timestamp + INITIAL_REDEMPTION_DELAY);
        _deposit(userOne);

        //then
        assertEq(accessManager.getAccountLockTime(userOne), block.timestamp + INITIAL_REDEMPTION_DELAY);
    }

    function testShouldGetAccountLockTimeIgnoreExemption() public {
        //given
        uint256 depositTs = block.timestamp;
        _deposit(userOne);
        _deposit(userTwo);

        //when
        _setExemption(_accounts(userOne), true);

        //then: the view stays exemption-agnostic
        assertEq(accessManager.getAccountLockTime(userOne), depositTs + INITIAL_REDEMPTION_DELAY);
        assertEq(accessManager.getAccountLockTime(userTwo), depositTs + INITIAL_REDEMPTION_DELAY);
    }

    function testShouldKeepExemptionListWhenRedemptionDelayChanges() public {
        //given
        _setExemption(_accounts(userOne, userTwo), true);

        //when/then
        _setRedemptionDelay(0);
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userOne, userTwo));
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);

        _setRedemptionDelay(7 days);
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userOne, userTwo));
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);

        _setRedemptionDelay(0);
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userOne, userTwo));
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);
        assertTrue(accessManager.isRedemptionDelayExempt(userOne));
    }

    function testShouldNeverLockAccountThatWasNeverExemptAndNeverDeposited() public {
        //given
        _setExemption(_accounts(userOne), true);

        //then
        assertEq(accessManager.getAccountLockTime(userTwo), 0);
        bytes4[] memory selectors = _gatedSelectors();
        for (uint256 i; i < selectors.length; i++) {
            _withdrawCheck(userTwo, selectors[i]);
        }
    }

    // --------------------------------------------------------------- getters

    function testShouldReadWholeExemptionListInOneCall() public {
        //given
        assertEq(accessManager.getRedemptionDelayExemptions().length, 0);
        address[] memory accounts = _accounts(userOne, userTwo, userThree);
        _setExemption(accounts, true);

        //then
        assertEq(accessManager.getRedemptionDelayExemptions(), accounts);

        //when
        _setExemption(_accounts(userOne), false);

        //then: EnumerableSet swap-and-pop order
        assertEq(accessManager.getRedemptionDelayExemptions(), _accounts(userThree, userTwo));
    }

    function testShouldReturnExemptionsCount() public {
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 0);

        _setExemption(_accounts(userOne, userTwo), true);
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);

        _setExemption(_accounts(userOne, userOne), true);
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 2);

        _setExemption(_accounts(userOne), false);
        assertEq(accessManager.getRedemptionDelayExemptionsCount(), 1);
    }

    function testShouldPaginateExemptions() public {
        //given
        address[] memory all = _fillExemptions(5);

        //when/then: pages of 2
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(0, 2), all, 0, 2);
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(2, 2), all, 2, 2);
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(4, 2), all, 4, 1);

        //then: edge cases
        assertEq(accessManager.getRedemptionDelayExemptionsAt(5, 2).length, 0, "offset == count");
        assertEq(accessManager.getRedemptionDelayExemptionsAt(6, 2).length, 0, "offset > count");
        assertEq(accessManager.getRedemptionDelayExemptionsAt(type(uint256).max, 2).length, 0, "huge offset");
        assertEq(accessManager.getRedemptionDelayExemptionsAt(0, 0).length, 0, "limit 0");
        assertEq(accessManager.getRedemptionDelayExemptionsAt(2, 0).length, 0, "limit 0 inside range");
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(3, 100), all, 3, 2);
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(0, type(uint256).max), all, 0, 5);
        _assertSlice(accessManager.getRedemptionDelayExemptionsAt(1, type(uint256).max), all, 1, 4);
    }

    function testFuzzShouldPaginateConsistentlyWithFullList(uint256 count_, uint256 offset_, uint256 limit_) public {
        //given
        uint256 count = bound(count_, 0, 12);
        address[] memory all = _fillExemptions(count);
        offset_ = bound(offset_, 0, 16);
        limit_ = bound(limit_, 0, 16);

        //when
        address[] memory page = accessManager.getRedemptionDelayExemptionsAt(offset_, limit_);

        //then: the page is the matching slice of the full list
        uint256 expected = offset_ >= count ? 0 : count - offset_;
        if (expected > limit_) {
            expected = limit_;
        }
        _assertSlice(page, all, offset_, expected);
    }

    // ----------------------------------------------------- storage and gas

    function testShouldKeepExemptionsInOwnNamespace() public {
        //given
        uint256 depositTs = block.timestamp;
        _deposit(userOne);
        bytes32 lockStartSlot = keccak256(abi.encode(userOne, LOCK_START_TIMES_SLOT));
        assertEq(uint256(vm.load(address(accessManager), lockStartSlot)), depositTs, "lock start before");
        uint256 delayBefore = accessManager.REDEMPTION_DELAY_IN_SECONDS();

        //when
        _setExemption(_accounts(userOne, userTwo), true);

        //then: AddressSet layout at the namespace slot
        assertEq(uint256(vm.load(address(accessManager), EXEMPTIONS_SLOT)), 2, "values length");
        assertEq(
            vm.load(address(accessManager), keccak256(abi.encode(EXEMPTIONS_SLOT))),
            bytes32(uint256(uint160(userOne))),
            "first element"
        );
        assertEq(
            vm.load(address(accessManager), bytes32(uint256(keccak256(abi.encode(EXEMPTIONS_SLOT))) + 1)),
            bytes32(uint256(uint160(userTwo))),
            "second element"
        );
        assertEq(uint256(vm.load(address(accessManager), _positionSlot(userOne))), 1, "position of first");
        assertEq(uint256(vm.load(address(accessManager), _positionSlot(userTwo))), 2, "position of second");

        //then: neighbouring storage untouched
        assertEq(uint256(vm.load(address(accessManager), lockStartSlot)), depositTs, "lock start after add");
        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), delayBefore, "delay");
        assertEq(uint256(vm.load(address(accessManager), bytes32(CUSTOM_CONSUMING_SCHEDULE_SLOT))), 0, "slot 4");

        //when
        _setExemption(_accounts(userOne, userTwo), false);

        //then
        assertEq(uint256(vm.load(address(accessManager), EXEMPTIONS_SLOT)), 0, "values length after revoke");
        assertEq(uint256(vm.load(address(accessManager), _positionSlot(userOne))), 0, "position cleared");
        assertEq(uint256(vm.load(address(accessManager), lockStartSlot)), depositTs, "lock start after revoke");
        assertEq(accessManager.getAccountLockTime(userOne), depositTs + delayBefore);
        assertEq(uint256(vm.load(address(accessManager), bytes32(CUSTOM_CONSUMING_SCHEDULE_SLOT))), 0, "slot 4");
    }

    function testShouldNotReadExemptionStorageOnUnlockedNonExemptExit() public {
        //given: expired lock, other accounts exempt
        _fillExemptions(3);
        _deposit(userOne);
        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY);

        //when
        vm.record();
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        (bytes32[] memory reads, ) = vm.accesses(address(accessManager));

        //then: the lock start was read (positive control), exemption storage was not
        assertTrue(_contains(reads, keccak256(abi.encode(userOne, LOCK_START_TIMES_SLOT))), "lock start read");
        assertFalse(_contains(reads, EXEMPTIONS_SLOT), "set length read");
        assertFalse(_contains(reads, _positionSlot(userOne)), "position read");
    }

    function testShouldReadExemptionStorageOnlyWhenAccountWouldBeLocked() public {
        //given: exempt and still locked
        _setExemption(_accounts(userOne), true);
        _deposit(userOne);

        //when
        vm.record();
        _withdrawCheck(userOne, PlasmaVault.withdraw.selector);
        (bytes32[] memory reads, ) = vm.accesses(address(accessManager));

        //then
        assertTrue(_contains(reads, _positionSlot(userOne)), "position read");
    }

    function testShouldNotChangeGasOfUnlockedExitWithExemptionListSize() public {
        //given: unlocked non-exempt account
        _deposit(userOne);
        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY);

        //when: empty list
        uint256 gasEmptyList = _coldExitGas(userOne, PlasmaVault.withdraw.selector);

        //when: 64 other exempt entries
        _fillExemptions(64);
        uint256 gasBigList = _coldExitGas(userOne, PlasmaVault.withdraw.selector);

        //then
        assertGt(gasEmptyList, 0);
        assertEq(gasBigList, gasEmptyList, "exit gas must not depend on the list size");
    }

    function testShouldCostAtMostOneColdReadForExemptLockedExit() public {
        //given
        _deposit(userOne);
        _deposit(userTwo);
        _setExemption(_accounts(userTwo), true);

        //when: userOne unlocked and non-exempt, userTwo locked and exempt (userOne measured after expiry)
        uint256 gasExemptLocked = _coldExitGas(userTwo, PlasmaVault.withdraw.selector);
        vm.warp(block.timestamp + INITIAL_REDEMPTION_DELAY);
        uint256 gasUnlocked = _coldExitGas(userOne, PlasmaVault.withdraw.selector);

        //then
        assertGe(gasExemptLocked, gasUnlocked, "exemption lookup is not free");
        assertLe(gasExemptLocked - gasUnlocked, COLD_SLOAD_GAS, "at most one cold read extra");
    }

    // --------------------------------------------------------------- helpers

    function _coldExitGas(address account_, bytes4 selector_) private returns (uint256) {
        vm.cool(address(accessManager));
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(account_, PLASMA_VAULT, selector_);
        return vm.lastCallGas().gasTotalUsed;
    }

    function _positionSlot(address account_) private pure returns (bytes32) {
        return keccak256(abi.encode(bytes32(uint256(uint160(account_))), uint256(EXEMPTIONS_SLOT) + 1));
    }

    function _contains(bytes32[] memory slots_, bytes32 slot_) private pure returns (bool) {
        for (uint256 i; i < slots_.length; i++) {
            if (slots_[i] == slot_) {
                return true;
            }
        }
        return false;
    }

    /// @dev Adds `count_` synthetic exempt addresses (distinct from the named users) and returns them in set order
    function _fillExemptions(uint256 count_) private returns (address[] memory accounts) {
        accounts = new address[](count_);
        for (uint256 i; i < count_; i++) {
            accounts[i] = address(uint160(0x10000 + i));
        }
        _setExemption(accounts, true);
    }

    function _assertSlice(
        address[] memory page_,
        address[] memory all_,
        uint256 offset_,
        uint256 expectedLength_
    ) private pure {
        assertEq(page_.length, expectedLength_, "page length");
        for (uint256 i; i < page_.length; i++) {
            assertEq(page_[i], all_[offset_ + i], "page element");
        }
    }

    function _gatedSelectors() private pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](4);
        selectors[0] = PlasmaVault.withdraw.selector;
        selectors[1] = PlasmaVault.redeem.selector;
        selectors[2] = PlasmaVault.transfer.selector;
        selectors[3] = PlasmaVault.transferFrom.selector;
    }

    function _accounts(address a_) private pure returns (address[] memory accounts) {
        accounts = new address[](1);
        accounts[0] = a_;
    }

    function _accounts(address a_, address b_) private pure returns (address[] memory accounts) {
        accounts = new address[](2);
        accounts[0] = a_;
        accounts[1] = b_;
    }

    function _accounts(address a_, address b_, address c_) private pure returns (address[] memory accounts) {
        accounts = new address[](3);
        accounts[0] = a_;
        accounts[1] = b_;
        accounts[2] = c_;
    }

    function _setExemption(address[] memory accounts_, bool exempt_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.setRedemptionDelayExemption(accounts_, exempt_);
    }

    function _setRedemptionDelay(uint256 redemptionDelayInSeconds_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.setRedemptionDelay(redemptionDelayInSeconds_);
    }

    function _deposit(address account_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(account_, PLASMA_VAULT, PlasmaVault.deposit.selector);
    }

    function _withdrawCheck(address account_, bytes4 selector_) private {
        vm.prank(PLASMA_VAULT);
        accessManager.canCallAndUpdate(account_, PLASMA_VAULT, selector_);
    }

    function _generateInitializationData() private returns (InitializationData memory) {
        DataForInitialization memory data;

        data.admins = new address[](1);
        data.admins[0] = admin;
        data.owners = new address[](1);
        data.owners[0] = owner;
        data.atomists = new address[](1);
        data.atomists[0] = atomist;
        data.iporDaos = new address[](0);
        data.alphas = new address[](0);
        data.whitelist = new address[](0);
        data.guardians = new address[](0);
        data.fuseManagers = new address[](0);
        data.claimRewards = new address[](0);
        data.transferRewardsManagers = new address[](0);
        data.configInstantWithdrawalFusesManagers = new address[](0);
        data.updateMarketsBalancesAccounts = new address[](0);
        data.updateRewardsBalanceAccounts = new address[](0);
        data.withdrawManagerRequestFeeManagers = new address[](0);
        data.withdrawManagerWithdrawFeeManagers = new address[](0);
        data.priceOracleMiddlewareManagers = new address[](0);
        data.preHooksManagers = new address[](0);

        /// @dev Dummy non-zero addresses, the initializer requires every manager address to be set
        address dummyManager = address(0x123);
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: PLASMA_VAULT,
            accessManager: address(accessManager),
            rewardsClaimManager: dummyManager,
            withdrawManager: dummyManager,
            feeManager: dummyManager,
            contextManager: dummyManager,
            priceOracleMiddlewareManager: dummyManager
        });

        return IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(data);
    }
}
