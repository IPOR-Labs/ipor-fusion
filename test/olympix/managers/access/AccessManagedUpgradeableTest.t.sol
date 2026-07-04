// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {AccessManagedUpgradeableHarness} from "test/test_helpers/AccessManagedUpgradeableHarness.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @dev Target contract: contracts/managers/access/AccessManagedUpgradeable.sol
/// @dev Abstract — exercised via AccessManagedUpgradeableHarness (test/test_helpers/).

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
contract AccessManagedUpgradeableTest is OlympixUnitTest("AccessManagedUpgradeable") {
    AccessManagedUpgradeableHarness internal target;
    address internal authority;
    address internal newAuthority;
    address internal caller;

    function setUp() public override {
        authority = address(0xA117);
        newAuthority = address(0xB117);
        caller = address(0xCA11);

        // Authority addresses need code so setAuthority's `code.length` check passes.
        vm.etch(authority, hex"60006000");
        vm.etch(newAuthority, hex"60006000");

        target = new AccessManagedUpgradeableHarness();
        target.initialize(authority);
    }

    function _mockAuthorityAllow(address authority_, address caller_, bytes4 sig_, bool immediate_, uint32 delay_)
        internal
    {
        vm.mockCall(
            authority_,
            abi.encodeWithSelector(IAccessManager.canCall.selector, caller_, address(target), sig_),
            abi.encode(immediate_, delay_)
        );
    }

    function test_example_authorityReturnsInitialAuthority() public view {
        assertEq(target.authority(), authority);
    }

    function test_example_isConsumingScheduledOpDefaultsToZero() public view {
        assertEq(target.isConsumingScheduledOp(), bytes4(0));
    }

    function test_example_setAuthorityByCurrentAuthoritySucceeds() public {
        vm.prank(authority);
        target.setAuthority(newAuthority);
        assertEq(target.authority(), newAuthority);
    }

    function test_setAuthority_RevertWhenCallerNotCurrentAuthority_branch101True() public {
            // caller is not the current authority, so (caller != authority()) is true and branch 101-True is taken
            vm.prank(caller);
            vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
            target.setAuthority(newAuthority);
        }
    

    function test_setAuthorityRevertsWhenNewAuthorityHasNoCode_branch106True() public {
            // Arrange: choose an address with no code so newAuthority.code.length == 0 is true
            address eoaAuthority = address(0xE0A1);
            assertEq(eoaAuthority.code.length, 0);
    
            // Act & Assert: call as current authority and expect the custom error
            vm.prank(authority);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessManaged.AccessManagedInvalidAuthority.selector, eoaAuthority)
            );
            target.setAuthority(eoaAuthority);
        }
}