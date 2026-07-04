// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {FuseWhitelistLibCaller} from "test/test_helpers/lib_callers/FuseWhitelistLibCaller.sol";

/// @dev Target: FuseWhitelistLibCaller (library FuseWhitelistLib wrapped for Olympix targeting).

import {FuseWhitelistLib} from "contracts/fuses/whitelist/FuseWhitelistLib.sol";
contract FuseWhitelistLibTest is OlympixUnitTest("FuseWhitelistLibCaller") {
    FuseWhitelistLibCaller internal caller;

    function setUp() public override {
        caller = new FuseWhitelistLibCaller();
    }

    function test_example_deploys() public view {
        assertTrue(address(caller) != address(0));
    }

    function test_addAndRetrieveFuseTypesAndMetadata() public {
            // add fuse types
            caller.addFuseType(1, "Supply Fuse");
            caller.addFuseType(2, "Borrow Fuse");
    
            // add fuse states
            caller.addFuseState(1, "Active");
            caller.addFuseState(2, "Deprecated");
    
            // add metadata types
            caller.addMetadataType(1, "Risk");
            caller.addMetadataType(2, "Category");
    
            // read back fuse types and verify
            (uint16[] memory typeIds, string[] memory typeDescs) = caller.getFuseTypes();
            assertEq(typeIds.length, 2, "two fuse types stored");
            assertEq(typeIds[0], 1, "first type id");
            assertEq(typeIds[1], 2, "second type id");
            assertEq(keccak256(bytes(typeDescs[0])), keccak256(bytes("Supply Fuse")), "first type desc");
            assertEq(keccak256(bytes(typeDescs[1])), keccak256(bytes("Borrow Fuse")), "second type desc");
    
            // single type description getter
            string memory desc1 = caller.getFuseTypeDescription(1);
            string memory desc2 = caller.getFuseTypeDescription(2);
            assertEq(keccak256(bytes(desc1)), keccak256(bytes("Supply Fuse")), "desc1 via getter");
            assertEq(keccak256(bytes(desc2)), keccak256(bytes("Borrow Fuse")), "desc2 via getter");
    
            // read back fuse states and verify
            (uint16[] memory stateIds, string[] memory stateNames) = caller.getFuseStates();
            assertEq(stateIds.length, 2, "two fuse states stored");
            assertEq(stateIds[0], 1, "first state id");
            assertEq(stateIds[1], 2, "second state id");
            assertEq(keccak256(bytes(stateNames[0])), keccak256(bytes("Active")), "first state name");
            assertEq(keccak256(bytes(stateNames[1])), keccak256(bytes("Deprecated")), "second state name");
    
            // single state name getter
            string memory st1 = caller.getFuseStateName(1);
            string memory st2 = caller.getFuseStateName(2);
            assertEq(keccak256(bytes(st1)), keccak256(bytes("Active")), "state1 via getter");
            assertEq(keccak256(bytes(st2)), keccak256(bytes("Deprecated")), "state2 via getter");
    
            // read back metadata types and verify
            (uint16[] memory metaIds, string[] memory metaNames) = caller.getMetadataTypes();
            assertEq(metaIds.length, 2, "two metadata types stored");
            assertEq(metaIds[0], 1, "first metadata id");
            assertEq(metaIds[1], 2, "second metadata id");
            assertEq(keccak256(bytes(metaNames[0])), keccak256(bytes("Risk")), "first metadata name");
            assertEq(keccak256(bytes(metaNames[1])), keccak256(bytes("Category")), "second metadata name");
    
            // single metadata getter
            string memory m1 = caller.getMetadataType(1);
            string memory m2 = caller.getMetadataType(2);
            assertEq(keccak256(bytes(m1)), keccak256(bytes("Risk")), "metadata1 via getter");
            assertEq(keccak256(bytes(m2)), keccak256(bytes("Category")), "metadata2 via getter");
        }

    function test_getFuseTypes_AfterAddingType() public {
            // given: add a fuse type via the caller (writes into FuseWhitelistLib storage)
            caller.addFuseType(1, "Test Fuse Type");
    
            // when: read back fuse types through the branch-marked getter
            (uint16[] memory typeIds, string[] memory descriptions) = caller.getFuseTypes();
    
            // then: verify the just-added type is present
            bool found;
            for (uint256 i = 0; i < typeIds.length; i++) {
                if (typeIds[i] == 1) {
                    found = true;
                    assertEq(descriptions[i], "Test Fuse Type");
                    break;
                }
            }
            assertTrue(found);
        }

    function test_getFuseTypeDescription_ReturnsAddedDescription() public {
            // add a fuse type with id 1 and description "desc"
            caller.addFuseType(1, "desc");
    
            // call the targeted function and verify it returns the stored description
            string memory returnedDesc = caller.getFuseTypeDescription(1);
            assertEq(returnedDesc, "desc");
        }

    function test_addFuseState_storesStateAndIsRetrievable() public {
            // given
            uint16 stateId = 1;
            string memory stateName = "ACTIVE";
    
            // when
            caller.addFuseState(stateId, stateName);
    
            // then
            (uint16[] memory ids, string[] memory names) = caller.getFuseStates();
            bool found;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == stateId) {
                    found = true;
                    assertEq(names[i], stateName, "stored state name mismatch");
                    break;
                }
            }
            assertTrue(found, "state id not found in stored fuse states");
    
            // also check direct getter
            string memory fetchedName = caller.getFuseStateName(stateId);
            assertEq(fetchedName, stateName, "getFuseStateName should return stored name");
        }

    function test_getFuseStates_ReturnsEmptyArraysByDefault() public view {
            (uint16[] memory stateIds, string[] memory stateNames) = caller.getFuseStates();
    
            assertEq(stateIds.length, 0, "expected no fuse states by default");
            assertEq(stateNames.length, 0, "expected no fuse state names by default");
        }

    function test_getFuseStateName_ReturnsStoredName() public {
            // arrange: add a fuse state with id 1 and name "ACTIVE"
            caller.addFuseState(1, "ACTIVE");
    
            // act: read back the state name via the wrapped library call
            string memory name = caller.getFuseStateName(1);
    
            // assert: verify it matches what we stored
            assertEq(name, "ACTIVE");
        }

    function test_addMetadataType_storesTypeAndName() public {
            // given
            uint16 metadataTypeId = 1;
            string memory metadataTypeName = "auditStatus";
    
            // when
            caller.addMetadataType(metadataTypeId, metadataTypeName);
    
            // then
            (uint16[] memory types, string[] memory names) = caller.getMetadataTypes();
            bool found;
            for (uint256 i = 0; i < types.length; i++) {
                if (types[i] == metadataTypeId) {
                    found = true;
                    assertEq(names[i], metadataTypeName, "Metadata type name mismatch");
                    break;
                }
            }
            assertTrue(found, "Metadata type id not stored");
    
            // also verify single getter
            string memory singleName = caller.getMetadataType(metadataTypeId);
            assertEq(singleName, metadataTypeName, "Single metadata type getter mismatch");
        }

    function test_getMetadataTypesAfterAdd() public {
            // given: add a metadata type via caller which uses FuseWhitelistLib under the hood
            uint16 metaTypeId = 1;
            string memory metaTypeName = "TEST_META";
            caller.addMetadataType(metaTypeId, metaTypeName);
    
            // when: retrieving metadata types directly from the library wrapper
            (uint16[] memory ids, string[] memory names) = caller.getMetadataTypes();
    
            // then: verify that the added metadata type is present
            bool found;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == metaTypeId) {
                    found = true;
                    assertEq(names[i], metaTypeName, "Metadata type name mismatch");
                    break;
                }
            }
            assertTrue(found, "Expected metadata type not found");
        }

    function test_getMetadataType_ReturnsCorrectName() public {
            // arrange: add a metadata type with id 39 and some name
            caller.addMetadataType(39, "MetaName");
    
            // act
            string memory result = caller.getMetadataType(39);
    
            // assert
            assertEq(result, "MetaName");
        }

    function test_isFuseAddressExists_DefaultFalse() public view {
            // No fuse addresses have been added to the FuseWhitelistLib storage for this caller yet.
            // Querying any arbitrary address should therefore return false.
            address someFuse = address(0x1234);
    
            bool exists = caller.isFuseAddressExists(someFuse);
    
            assertFalse(exists, "Expected fuse address to not exist by default");
        }

    function test_getFusesByType_EmptyWhenNoneAdded() public view {
        uint16 fuseType = 1;
    
        address[] memory fuses = caller.getFusesByType(fuseType);
    
        assertEq(fuses.length, 0, "Expected no fuses for type when none added");
    }

    function test_getFusesByMarketId_returnsEmptyWhenNoneConfigured() public view {
            uint256 marketId = 1;
            address[] memory fuses = caller.getFusesByMarketId(marketId);
            assertEq(fuses.length, 0, "Expected no fuses configured for this marketId");
        }
}