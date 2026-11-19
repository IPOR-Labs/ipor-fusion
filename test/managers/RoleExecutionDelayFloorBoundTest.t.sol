// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {
    InitializationData,
    RoleToFunction,
    AccountToRole,
    AdminRole
} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev IL-9676: a role delay floor above `type(uint32).max` can never be satisfied by a grant, so it must be rejected.
contract RoleExecutionDelayFloorBoundTest is Test {
    address private constant ADMIN = address(0x1);
    address private constant HOLDER = address(0x2);
    uint64 private constant ROLE_ID = Roles.ATOMIST_ROLE;

    IporFusionAccessManager private _accessManager;

    function setUp() public {
        _accessManager = new IporFusionAccessManager(ADMIN, 0);
    }

    function _data(uint256 floor_, bool grant_) private view returns (InitializationData memory data) {
        data.roleToFunctions = new RoleToFunction[](1);
        data.roleToFunctions[0] = RoleToFunction({
            target: address(_accessManager),
            roleId: ROLE_ID,
            functionSelector: IporFusionAccessManager.setRedemptionDelay.selector,
            minimalExecutionDelay: floor_
        });
        data.adminRoles = new AdminRole[](0);
        data.accountToRoles = new AccountToRole[](grant_ ? 1 : 0);
        if (grant_) {
            data.accountToRoles[0] = AccountToRole({
                roleId: ROLE_ID,
                account: HOLDER,
                executionDelay: type(uint32).max
            });
        }
    }

    function testShouldRevertWhenDelayFloorExceedsUint32Max() public {
        // given
        uint256 floor = uint256(type(uint32).max) + 1;
        InitializationData memory data = _data(floor, false);

        // when / then
        vm.expectRevert(
            abi.encodeWithSignature("RoleExecutionTimelockLibDelayFloorTooLarge(uint64,uint256)", ROLE_ID, floor)
        );
        vm.prank(ADMIN);
        _accessManager.initialize(data);
    }

    function testShouldAcceptUint32MaxFloorAndGrantRoleWithIt() public {
        // given
        InitializationData memory data = _data(type(uint32).max, true);

        // when
        vm.prank(ADMIN);
        _accessManager.initialize(data);

        // then
        assertEq(_accessManager.getMinimalExecutionDelayForRole(ROLE_ID), type(uint32).max, "floor stored");
        (bool isMember, uint32 executionDelay) = _accessManager.hasRole(ROLE_ID, HOLDER);
        assertTrue(isMember, "role granted");
        assertEq(executionDelay, type(uint32).max, "execution delay");
    }
}
