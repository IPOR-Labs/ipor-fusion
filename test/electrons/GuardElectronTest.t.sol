// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {GuardElectron} from "../../contracts/electrons/GuardElectron.sol";
import {TimeLockType} from "../../contracts/electrons/IGuardElectron.sol";

contract GuardElectronTest is Test {
    address private _atomist;
    address private _actorOne;
    GuardElectron private _guardElectron;

    function setUp() public {
        _atomist = address(0x1000);
        _actorOne = address(0x11111);
        _guardElectron = new GuardElectron(_atomist, 1 hours);
    }

    function testShouldRevertWhenAtomistZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0x0));

        // when
        vm.expectRevert(error);
        new GuardElectron(address(0), 1 hours);
    }

    function testShouldRevertWhenMinimalTimeLockLessThanOneHour() external {
        // given
        bytes memory error = abi.encodeWithSignature("TimeLockError(uint256,uint256)", 59 minutes, 1 hours);

        // when
        vm.expectRevert(error);
        new GuardElectron(_atomist, 59 minutes);
    }

    function testShouldReturnAtomistAddress() external {
        // when
        address atomist = _guardElectron.getAtomist();

        // then
        assertEq(_atomist, atomist, "Initial atomist address should be returned");
    }

    function testShouldRevertWhenSetTimeLockLessThanMinimalTimeLock() external {
        // given
        bytes memory error = abi.encodeWithSignature("TimeLockError(uint256,uint256)", 59 minutes, 1 hours);

        // when
        vm.expectRevert(error);
        vm.prank(_atomist);
        _guardElectron.setTimeLock(TimeLockType.AtomistTransfer, 59 minutes);
    }

    function testShouldRevertWhenSetTimlockSendNotByAtomist() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        // when
        vm.expectRevert(error);
        _guardElectron.setTimeLock(TimeLockType.AtomistTransfer, 2 hours);
    }

    function testShouldBeAbleToUpdateTimeLockForAtomistTransfer() external {
        uint256 timeLockBefore = _guardElectron.timeLocks(TimeLockType.AtomistTransfer);
        // when
        vm.prank(_atomist);
        _guardElectron.setTimeLock(TimeLockType.AtomistTransfer, 2 hours);

        // then
        uint256 timeLockAfter = _guardElectron.timeLocks(TimeLockType.AtomistTransfer);

        assertEq(1 hours, timeLockBefore, "Time lock for AtomistTransfer should be 1 hour");
        assertEq(2 hours, timeLockAfter, "Time lock for AtomistTransfer should be updated");
    }

    function testShouldBeAbleToSetupTimeLockForAccessControl() external {
        uint256 timeLockBefore = _guardElectron.timeLocks(TimeLockType.AccessControl);
        // when
        vm.prank(_atomist);
        _guardElectron.setTimeLock(TimeLockType.AccessControl, 2 hours);

        // then
        uint256 timeLockAfter = _guardElectron.timeLocks(TimeLockType.AccessControl);

        assertEq(1 hours, timeLockBefore, "Time lock for AccessControl should be 1 hour");
        assertEq(2 hours, timeLockAfter, "Time lock for AccessControl should be updated");
    }

    function testShouldRevertWhenNotAtomistSetupAppointedToAccess() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        // when
        vm.expectRevert(error);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
    }

    function testShouldBeAbleToAppointToAccess() external {
        // given
        bytes32 key = keccak256(abi.encodePacked(address(this), bytes4(keccak256("test1()")), _actorOne));
        bool isAppointedBefore = _guardElectron.appointedToGrantAccess(key) == 1;

        // when
        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        bool isAppointedAfter = _guardElectron.appointedToGrantAccess(key) == 1;

        assertFalse(isAppointedBefore, "Actor should not be appointed before");
        assertTrue(isAppointedAfter, "Actor should be appointed after");
    }

    function testShouldRewertWhenNotAtomistTryToGrantAccess() external {
        // given
        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        vm.warp(block.timestamp + 2 hours);

        // when
        vm.expectRevert(error);
        _guardElectron.grantAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
    }

    function testShouldRevertWhenTryToGrantAccessBeforeTimeLock() external {
        // given
        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
        bytes memory error = abi.encodeWithSignature(
            "TimeLockError(uint256,uint256)",
            block.timestamp,
            block.timestamp + 1 hours
        );

        // when
        vm.expectRevert(error);
        vm.prank(_atomist);
        _guardElectron.grantAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
    }

    function testShouldBeAbleToGrantAccess() external {
        // given
        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        vm.warp(block.timestamp + 2 hours);

        bool hasAccessBefore = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // when
        vm.prank(_atomist);
        _guardElectron.grantAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        bool hasAccessAfter = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        assertFalse(hasAccessBefore, "Actor should not have access before");
        assertTrue(hasAccessAfter, "Actor should have access after");
    }

    function testShouldRevertWhenNotAtomistTryToRevokeAccess() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(_atomist);
        _guardElectron.grantAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        bool hasAccessBefore = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // when
        vm.expectRevert(error);
        _guardElectron.revokeAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        bool hasAccessAfter = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        assertTrue(hasAccessBefore, "Actor should have access before");
        assertTrue(hasAccessAfter, "Actor should have access after");
    }

    function testShouldBeAbleToRevokeAccess() external {
        // given
        vm.prank(_atomist);
        _guardElectron.appointedToAccess(address(this), bytes4(keccak256("test1()")), _actorOne);
        vm.warp(block.timestamp + 2 hours);

        vm.prank(_atomist);
        _guardElectron.grantAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        bool hasAccessBefore = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // when
        vm.prank(_atomist);
        _guardElectron.revokeAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        bool hasAccessAfter = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        assertTrue(hasAccessBefore, "Actor should have access before");
        assertFalse(hasAccessAfter, "Actor should not have access after");
    }

    function testShouldRevertWhenNotAtomistTryToTransferOwnership() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        // when
        vm.expectRevert(error);
        _guardElectron.transferOwnership(_actorOne);
    }

    function testShouldBeAbleToTransferOwnership() external {
        // given
        vm.warp(block.timestamp + 2 hours);
        bool isAppointedToTransferOwnershipBefore = _guardElectron.appointedTimeLocks(TimeLockType.AtomistTransfer) > 1;

        // when
        vm.prank(_atomist);
        _guardElectron.transferOwnership(_actorOne);

        // then
        bool isAppointedToTransferOwnershipAfter = _guardElectron.appointedTimeLocks(TimeLockType.AtomistTransfer) > 1;

        assertFalse(isAppointedToTransferOwnershipBefore, "Ownership should not be appointed before");
        assertTrue(isAppointedToTransferOwnershipAfter, "Ownership should be appointed after");
    }

    function testShouldRevertWhenTryToAcceptOwnershipBeforeTimeLock() external {
        // given
        vm.warp(block.timestamp + 2 hours);

        vm.prank(_atomist);
        _guardElectron.transferOwnership(_actorOne);

        bool isAppointedToTransferOwnershipBefore = _guardElectron.appointedTimeLocks(TimeLockType.AtomistTransfer) > 1;

        vm.warp(block.timestamp + 56 minutes);

        bytes memory error = abi.encodeWithSignature("TimeLockError(uint256,uint256)", 10561, 10801);

        // when
        vm.expectRevert(error);
        vm.prank(_actorOne);
        _guardElectron.acceptOwnership();

        // then
        bool isAppointedToTransferOwnershipAfter = _guardElectron.appointedTimeLocks(TimeLockType.AtomistTransfer) > 1;

        assertTrue(isAppointedToTransferOwnershipBefore, "Ownership should be appointed before");
        assertTrue(isAppointedToTransferOwnershipAfter, "Ownership should be appointed after");
    }

    function testShouldBeAbleToAcceptOwnership() external {
        // given
        vm.warp(block.timestamp + 2 hours);

        vm.prank(_atomist);
        _guardElectron.transferOwnership(_actorOne);

        address atomistBefore = _guardElectron.getAtomist();

        vm.warp(block.timestamp + 2 hours);

        // when
        vm.prank(_actorOne);
        _guardElectron.acceptOwnership();

        // then
        address atomistAfter = _guardElectron.getAtomist();

        assertEq(_atomist, atomistBefore, "Atomist should be before");
        assertEq(_actorOne, atomistAfter, "Atomist should be after");
    }

    function testShouldRevertWhenNotAtomistTryAddPauseGuardian() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;

        // when
        vm.expectRevert(error);
        _guardElectron.addPauseGuardians(guardians);
    }

    function testShouldBeAbleToAddPauseGuardian() external {
        // given
        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;

        bool isPauseGuardBefore = _guardElectron.pauseGuards(_actorOne) == 1;

        // when
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        // then
        bool isPauseGuardAfter = _guardElectron.pauseGuards(_actorOne) == 1;

        assertFalse(isPauseGuardBefore, "Pause guard should not be before");
        assertTrue(isPauseGuardAfter, "Pause guard should be after");
    }

    function testShouldRevertWhenNotAtomistTryRemovePauseGuardian() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        bool isPauseGuardBefore = _guardElectron.pauseGuards(_actorOne) == 1;

        // when
        vm.expectRevert(error);
        _guardElectron.removePauseGuardians(guardians);

        // then
        bool isPauseGuardAfter = _guardElectron.pauseGuards(_actorOne) == 1;

        assertTrue(isPauseGuardBefore, "Pause guard should be before");
        assertTrue(isPauseGuardAfter, "Pause guard should be after");
    }

    function testShouldBeAbleToRemovePauseGuardian() external {
        // given
        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        bool isPauseGuardBefore = _guardElectron.pauseGuards(_actorOne) == 1;

        // when
        vm.prank(_atomist);
        _guardElectron.removePauseGuardians(guardians);

        // then
        bool isPauseGuardAfter = _guardElectron.pauseGuards(_actorOne) == 1;

        assertTrue(isPauseGuardBefore, "Pause guard should be before");
        assertFalse(isPauseGuardAfter, "Pause guard should not be after");
    }

    function testShouldRevertWhenNotPauseGuardianTryToPause() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotGuardian(address)", address(this));

        address[] memory contractAddresses = new address[](1);
        contractAddresses[0] = address(this);

        bytes4[] memory signatures = new bytes4[](1);
        signatures[0] = bytes4(keccak256("test1()"));
        bytes32 key = keccak256(abi.encodePacked(contractAddresses[0], signatures[0]));

        bool isPausedBefore = _guardElectron.pausedMethods(key) == 1;

        // when
        vm.expectRevert(error);
        _guardElectron.pause(contractAddresses, signatures);

        // then
        bool isPausedAfter = _guardElectron.pausedMethods(key) == 1;

        assertFalse(isPausedBefore, "Method should not be paused before");
        assertFalse(isPausedAfter, "Method should not be paused after");
    }

    function testShouldBeAbleToPause() external {
        // given
        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        address[] memory contractAddresses = new address[](1);
        contractAddresses[0] = address(this);

        bytes4[] memory signatures = new bytes4[](1);
        signatures[0] = bytes4(keccak256("test1()"));
        bytes32 key = keccak256(abi.encodePacked(contractAddresses[0], signatures[0]));

        bool isPausedBefore = _guardElectron.pausedMethods(key) == 1;

        // when
        vm.prank(_actorOne);
        _guardElectron.pause(contractAddresses, signatures);

        // then
        bool isPausedAfter = _guardElectron.pausedMethods(key) == 1;

        assertFalse(isPausedBefore, "Method should not be paused before");
        assertTrue(isPausedAfter, "Method should be paused after");
    }

    function testShouldRevertWhenArrayLengthMismatch() external {
        // given
        bytes memory error = abi.encodeWithSignature("ArrayLengthMismatch(uint256,uint256)", 1, 2);

        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        address[] memory contractAddresses = new address[](1);
        contractAddresses[0] = address(this);

        bytes4[] memory signatures = new bytes4[](2);
        signatures[0] = bytes4(keccak256("test1()"));
        signatures[1] = bytes4(keccak256("test2()"));

        // when
        vm.expectRevert(error);
        vm.prank(_actorOne);
        _guardElectron.pause(contractAddresses, signatures);
    }

    function testShouldRevertWhenNotAtomistTryToUnpause() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        address[] memory contractAddresses = new address[](1);
        contractAddresses[0] = address(this);

        bytes4[] memory signatures = new bytes4[](1);
        signatures[0] = bytes4(keccak256("test1()"));
        bytes32 key = keccak256(abi.encodePacked(contractAddresses[0], signatures[0]));

        vm.prank(_actorOne);
        _guardElectron.pause(contractAddresses, signatures);

        bool isPausedBefore = _guardElectron.pausedMethods(key) == 1;

        // when
        vm.expectRevert(error);
        _guardElectron.unpause(contractAddresses, signatures);

        // then
        bool isPausedAfter = _guardElectron.pausedMethods(key) == 1;

        assertTrue(isPausedBefore, "Method should be paused before");
        assertTrue(isPausedAfter, "Method should be paused after");
    }

    function testShouldBeAbleToUnpause() external {
        // given
        address[] memory guardians = new address[](1);
        guardians[0] = _actorOne;
        vm.prank(_atomist);
        _guardElectron.addPauseGuardians(guardians);

        address[] memory contractAddresses = new address[](1);
        contractAddresses[0] = address(this);

        bytes4[] memory signatures = new bytes4[](1);
        signatures[0] = bytes4(keccak256("test1()"));
        bytes32 key = keccak256(abi.encodePacked(contractAddresses[0], signatures[0]));

        vm.prank(_actorOne);
        _guardElectron.pause(contractAddresses, signatures);

        bool isPausedBefore = _guardElectron.pausedMethods(key) == 1;

        // when
        vm.prank(_atomist);
        _guardElectron.unpause(contractAddresses, signatures);

        // then
        bool isPausedAfter = _guardElectron.pausedMethods(key) == 1;

        assertTrue(isPausedBefore, "Method should be paused before");
        assertFalse(isPausedAfter, "Method should not be paused after");
    }

    function testShouldRevertWhenNotAtomistTryToDisableWhiteList() external {
        // given
        bytes memory error = abi.encodeWithSignature("SenderNotAtomist(address)", address(this));

        // when
        vm.expectRevert(error);
        _guardElectron.disableWhiteList(address(this), bytes4(keccak256("test1()")));
    }

    function testShouldBeAbleToDisableWhiteList() external {
        // given
        bytes32 key = keccak256(abi.encodePacked(address(this), bytes4(keccak256("test1()"))));
        bool isDisabledBefore = _guardElectron.disabledWhiteList(key) == 1;

        // when
        vm.prank(_atomist);
        _guardElectron.disableWhiteList(address(this), bytes4(keccak256("test1()")));

        // then
        bool isDisabledAfter = _guardElectron.disabledWhiteList(key) == 1;

        assertFalse(isDisabledBefore, "White list should not be disabled before");
        assertTrue(isDisabledAfter, "White list should be disabled after");
    }

    function testShouldHasNoAccessWhenInit() external {
        // when
        bool hasAccess = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        assertFalse(hasAccess, "Actor should not have access");
    }

    function testShouldHasAccessWhenDisabledWhiteList() external {
        // given
        vm.prank(_atomist);
        _guardElectron.disableWhiteList(address(this), bytes4(keccak256("test1()")));

        // when
        bool hasAccess = _guardElectron.hasAccess(address(this), bytes4(keccak256("test1()")), _actorOne);

        // then
        assertTrue(hasAccess, "Actor should have access");
    }
}
