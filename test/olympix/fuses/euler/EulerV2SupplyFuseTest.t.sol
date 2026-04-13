// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {EulerV2SupplyFuse} from "contracts/fuses/euler/EulerV2SupplyFuse.sol";

/// @dev Target contract: contracts/fuses/euler/EulerV2SupplyFuse.sol

import {Errors} from "contracts/libraries/errors/Errors.sol";
contract EulerV2SupplyFuseTest is OlympixUnitTest("EulerV2SupplyFuse") {
    EulerV2SupplyFuse public eulerV2SupplyFuse;


    function setUp() public override {
        eulerV2SupplyFuse = new EulerV2SupplyFuse(1, address(0xDEAD));
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(eulerV2SupplyFuse) != address(0), "Contract should be deployed");
    }

    function test_instantWithdraw_RevertsWhenParamsLengthLessThan3_opix_target_branch_203_true() public {
            bytes32[] memory params = new bytes32[](2);
            vm.expectRevert(EulerV2SupplyFuse.EulerV2SupplyFuseInvalidParams.selector);
            eulerV2SupplyFuse.instantWithdraw(params);
        }
}