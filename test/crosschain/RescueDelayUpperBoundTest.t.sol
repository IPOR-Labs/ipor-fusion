// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {RescueModule} from "../../contracts/crosschain/lib/RescueModule.sol";

contract RescueModuleHarness is RescueModule {
    constructor(
        address admin_,
        address guardian_,
        uint256 rescueDelay_
    ) RescueModule(admin_, guardian_, rescueDelay_) {}
}

/// @notice IL-9674: `RescueModule` rejects a rescue delay above 30 days; the bounds are inclusive.
contract RescueDelayUpperBoundTest is Test {
    address private constant ADMIN = address(0xA11CE);
    address private constant GUARDIAN = address(0xB0B);
    uint256 private constant MAX_DELAY = 30 days;
    uint256 private constant MIN_DELAY = 24 hours;

    function test_rescueDelayAboveMaxReverts() public {
        vm.expectRevert(abi.encodeWithSignature("RescueDelayTooLong(uint256,uint256)", MAX_DELAY + 1, MAX_DELAY));
        new RescueModuleHarness(ADMIN, GUARDIAN, MAX_DELAY + 1);
    }

    function test_rescueDelayAtMaxAccepted() public {
        RescueModuleHarness module = new RescueModuleHarness(ADMIN, GUARDIAN, MAX_DELAY);
        assertEq(module.RESCUE_DELAY(), MAX_DELAY);
    }

    function test_rescueDelayAtMinAccepted() public {
        RescueModuleHarness module = new RescueModuleHarness(ADMIN, GUARDIAN, MIN_DELAY);
        assertEq(module.RESCUE_DELAY(), MIN_DELAY);
    }

    function test_rescueDelayBelowMinStillReverts() public {
        vm.expectRevert(abi.encodeWithSignature("InvalidRescueDelay(uint256,uint256)", MIN_DELAY - 1, MIN_DELAY));
        new RescueModuleHarness(ADMIN, GUARDIAN, MIN_DELAY - 1);
    }
}
