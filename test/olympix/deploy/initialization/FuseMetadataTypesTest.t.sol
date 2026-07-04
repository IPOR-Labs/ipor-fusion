// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FuseMetadataTypesCaller} from "test/test_helpers/lib_callers/FuseMetadataTypesCaller.sol";
import {FuseMetadataTypes} from "contracts/deploy/initialization/FuseMetadataTypes.sol";

/// @dev Target: FuseMetadataTypesCaller (library FuseMetadataTypes wrapped for Olympix targeting).

contract FuseMetadataTypesTest is OlympixUnitTest("FuseMetadataTypesCaller") {
    FuseMetadataTypesCaller internal caller;

    function setUp() public override {
        caller = new FuseMetadataTypesCaller();
    }

    function test_example_auditStatusIdMatchesLib() public view {
        assertEq(caller.auditStatusId(), FuseMetadataTypes.FUSE_METADATA_AUDIT_STATUS_ID);
    }

    function test_example_unauditedCodeMatchesLib() public view {
        assertEq(caller.unauditedCode(), "UNAUDITED");
    }

    function test_opix_auditStatusNameMatchesLib() public view {
            assertEq(caller.auditStatusName(), FuseMetadataTypes.FUSE_METADATA_AUDIT_STATUS_NAME);
        }

    function test_auditedCodeMatchesLib() public view {
            assertEq(caller.auditedCode(), FuseMetadataTypes.FUSE_METADATA_AUDIT_STATUS_AUDITED_CODE);
        }

    function test_substrateInfoIdMatchesLib() public view {
            assertEq(caller.substrateInfoId(), FuseMetadataTypes.FUSE_METADATA_SUBSTRATE_INFO_ID);
        }

    function test_categoryInfoIdMatchesLib() public view {
            assertEq(caller.categoryInfoId(), FuseMetadataTypes.FUSE_METADATA_CATEGORY_INFO_ID);
        }

    function test_supplyCodeMatchesLibConstant() public view {
            assertEq(caller.supplyCode(), FuseMetadataTypes.FUSE_METADATA_CATEGORY_INFO_SUPPLY_CODE);
        }

    function test_abiVersionIdMatchesLib() public view {
            assertEq(caller.abiVersionId(), FuseMetadataTypes.FUSE_METADATA_ABI_VERSION_ID);
        }
}