// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FuseTypes} from "../../../contracts/deploy/initialization/FuseTypes.sol";
import {FuseMetadataTypes} from "../../../contracts/deploy/initialization/FuseMetadataTypes.sol";

contract FuseTypesHyperCoreTest is Test {
    function testShouldHaveMatchingIdsAndNamesLength() public pure {
        uint16[] memory ids = FuseTypes.getAllFuseIds();
        string[] memory names = FuseTypes.getAllFuseNames();

        assertEq(ids.length, names.length, "ids and names length mismatch");
    }

    function testShouldHaveUniqueAndStrictlyIncreasingIds() public pure {
        uint16[] memory ids = FuseTypes.getAllFuseIds();

        for (uint256 i = 1; i < ids.length; i++) {
            assertGt(ids[i], ids[i - 1], "fuse ids are not strictly increasing");
        }
    }

    function testShouldMapHyperCoreDepositFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_DEPOSIT_FUSE_ID, FuseTypes.HYPERCORE_DEPOSIT_FUSE_NAME);
    }

    function testShouldMapHyperCoreMarginFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_MARGIN_FUSE_ID, FuseTypes.HYPERCORE_MARGIN_FUSE_NAME);
    }

    function testShouldMapHyperCoreSendFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_SEND_FUSE_ID, FuseTypes.HYPERCORE_SEND_FUSE_NAME);
    }

    function testShouldMapHyperCoreOrderFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_ORDER_FUSE_ID, FuseTypes.HYPERCORE_ORDER_FUSE_NAME);
    }

    function testShouldMapHyperCoreCancelFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_CANCEL_FUSE_ID, FuseTypes.HYPERCORE_CANCEL_FUSE_NAME);
    }

    function testShouldMapHyperCoreBuilderFeeFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_BUILDER_FEE_FUSE_ID, FuseTypes.HYPERCORE_BUILDER_FEE_FUSE_NAME);
    }

    function testShouldMapHyperCoreBalanceFuseIdToName() public pure {
        _assertIdMapsToName(FuseTypes.HYPERCORE_BALANCE_FUSE_ID, FuseTypes.HYPERCORE_BALANCE_FUSE_NAME);
    }

    function testShouldNotExposeReservedHyperCoreSettlementFuseId115() public pure {
        uint16[] memory ids = FuseTypes.getAllFuseIds();

        for (uint256 i = 0; i < ids.length; i++) {
            assertTrue(ids[i] != 115, "fuse id 115 is reserved (removed HyperCoreSettlementFuse, IL-8543)");
        }
    }

    function testShouldHaveHyperCoreIds108To114Present() public pure {
        uint16[] memory ids = FuseTypes.getAllFuseIds();

        uint16[7] memory expectedIds = [
            uint16(108),
            uint16(109),
            uint16(110),
            uint16(111),
            uint16(112),
            uint16(113),
            uint16(114)
        ];

        for (uint256 i = 0; i < expectedIds.length; i++) {
            bool found = false;
            for (uint256 j = 0; j < ids.length; j++) {
                if (ids[j] == expectedIds[i]) {
                    found = true;
                    break;
                }
            }
            assertTrue(found, "expected HyperCore fuse id not present");
        }
    }

    function testShouldExposeHyperCoreProtocolMetadataCode() public pure {
        assertEq(FuseMetadataTypes.FUSE_METADATA_PROTOCOL_INFO_HYPERCORE_CODE, "HYPERCORE");
    }

    function _assertIdMapsToName(uint16 expectedId, string memory expectedName) internal pure {
        uint16[] memory ids = FuseTypes.getAllFuseIds();
        string[] memory names = FuseTypes.getAllFuseNames();

        bool found = false;
        for (uint256 i = 0; i < ids.length; i++) {
            if (ids[i] == expectedId) {
                found = true;
                assertEq(names[i], expectedName, "id/name index mismatch");
                break;
            }
        }
        assertTrue(found, "expected fuse id not found in getAllFuseIds()");
    }
}
