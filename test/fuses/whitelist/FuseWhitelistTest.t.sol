// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FuseWhitelist} from "../../../contracts/fuses/whitelist/FuseWhitelist.sol";
import {FuseWhitelistLib} from "../../../contracts/fuses/whitelist/FuseWhitelistLib.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";
import {Erc4626SupplyFuse} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {FuseTypes} from "../../../contracts/deploy/initialization/FuseTypes.sol";
import {FuseStatus} from "../../../contracts/deploy/initialization/FuseStatus.sol";
import {FuseMetadataTypes} from "../../../contracts/deploy/initialization/FuseMetadataTypes.sol";

contract FuseWhitelistTest is Test {
    FuseWhitelist private _fuseWhitelist;
    address ADMIN = TestAddresses.ADMIN;
    address FUSE_TYPE_MANAGER_ROLE = TestAddresses.ATOMIST;
    address FUSE_STATE_MANAGER_ROLE = TestAddresses.ATOMIST;
    address FUSE_METADATA_MANAGER_ROLE = TestAddresses.ATOMIST;
    address ADD_FUSE_MANAGER_ROLE = TestAddresses.ATOMIST;
    address UPDATE_FUSE_STATE_ROLE = TestAddresses.ATOMIST;
    address UPDATE_FUSE_METADATA_ROLE = TestAddresses.ATOMIST;

    function setUp() public {
        // Setup code will be added here
        _fuseWhitelist = FuseWhitelist(
            address(
                new ERC1967Proxy(address(new FuseWhitelist()), abi.encodeWithSignature("initialize(address)", ADMIN))
            )
        );

        vm.startPrank(ADMIN);
        _fuseWhitelist.grantRole(_fuseWhitelist.FUSE_TYPE_MANAGER_ROLE(), FUSE_TYPE_MANAGER_ROLE);
        _fuseWhitelist.grantRole(_fuseWhitelist.FUSE_STATE_MANAGER_ROLE(), FUSE_STATE_MANAGER_ROLE);
        _fuseWhitelist.grantRole(_fuseWhitelist.FUSE_METADATA_MANAGER_ROLE(), FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.grantRole(_fuseWhitelist.ADD_FUSE_MANAGER_ROLE(), ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.grantRole(_fuseWhitelist.UPDATE_FUSE_STATE_MANAGER_ROLE(), UPDATE_FUSE_STATE_ROLE);
        _fuseWhitelist.grantRole(_fuseWhitelist.UPDATE_FUSE_METADATA_MANAGER_ROLE(), UPDATE_FUSE_METADATA_ROLE);
        vm.stopPrank();
    }

    function test_AddFuseTypes_Success() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](3);
        string[] memory fuseTypeNames = new string[](3);

        fuseTypeIds[0] = 1;
        fuseTypeIds[1] = 2;
        fuseTypeIds[2] = 3;

        fuseTypeNames[0] = "Type1";
        fuseTypeNames[1] = "Type2";
        fuseTypeNames[2] = "Type3";

        (uint16[] memory fuseTypesIdsBefore, string[] memory fuseTypesNamesBefore) = _fuseWhitelist.getFuseTypes();

        // Act
        vm.prank(FUSE_TYPE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory fuseTypesIdsAfter, string[] memory fuseTypesNamesAfter) = _fuseWhitelist.getFuseTypes();

        assertEq(fuseTypesIdsBefore.length, 0, "Fuses types should be empty");
        assertEq(fuseTypesIdsAfter.length, fuseTypeIds.length, "Fuses types should be equal to the input");
        assertEq(fuseTypesNamesBefore.length, 0, "Fuses names should be empty");
        assertEq(fuseTypesNamesAfter.length, fuseTypeNames.length, "Fuses names should be equal to the input");
    }

    function test_AddFuseTypes_InvalidInputLength() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](2);
        string[] memory fuseTypeNames = new string[](3);

        fuseTypeIds[0] = 1;
        fuseTypeIds[1] = 2;

        fuseTypeNames[0] = "Type1";
        fuseTypeNames[1] = "Type2";
        fuseTypeNames[2] = "Type3";

        // Act & Assert
        vm.prank(FUSE_TYPE_MANAGER_ROLE);
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInputLength.selector);
        _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
    }

    function test_AddFuseTypes_Unauthorized() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](1);
        string[] memory fuseTypeNames = new string[](1);

        fuseTypeIds[0] = 1;
        fuseTypeNames[0] = "Type1";

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("FUSE_TYPE_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
    }

    function test_AddFuseTypes_EmptyInput() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](0);
        string[] memory fuseTypeNames = new string[](0);

        // Act
        vm.startPrank(FUSE_TYPE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true for empty input");
    }

    function test_AddFuseTypes_EventEmitted() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](2);
        string[] memory fuseTypeNames = new string[](2);

        fuseTypeIds[0] = 1;
        fuseTypeIds[1] = 2;

        fuseTypeNames[0] = "Type1";
        fuseTypeNames[1] = "Type2";

        // Act & Assert
        vm.startPrank(FUSE_TYPE_MANAGER_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseTypeAdded(1, "Type1");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseTypeAdded(2, "Type2");
        bool result = _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddFuseStates_Success() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](3);
        string[] memory fuseStateNames = new string[](3);

        fuseStateIds[0] = 1;
        fuseStateIds[1] = 2;
        fuseStateIds[2] = 3;

        fuseStateNames[0] = "State1";
        fuseStateNames[1] = "State2";
        fuseStateNames[2] = "State3";

        (uint16[] memory fuseStatesIdsBefore, string[] memory fuseStatesNamesBefore) = _fuseWhitelist.getFuseStates();

        // Act
        vm.prank(FUSE_STATE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory fuseStatesIdsAfter, string[] memory fuseStatesNamesAfter) = _fuseWhitelist.getFuseStates();

        assertEq(fuseStatesIdsBefore.length, 0, "Fuses states should be empty");
        assertEq(fuseStatesIdsAfter.length, fuseStateIds.length, "Fuses states should be equal to the input");
        assertEq(fuseStatesNamesBefore.length, 0, "Fuses names should be empty");
        assertEq(fuseStatesNamesAfter.length, fuseStateNames.length, "Fuses names should be equal to the input");
    }

    function test_AddFuseStates_InvalidInputLength() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](2);
        string[] memory fuseStateNames = new string[](3);

        fuseStateIds[0] = 1;
        fuseStateIds[1] = 2;

        fuseStateNames[0] = "State1";
        fuseStateNames[1] = "State2";
        fuseStateNames[2] = "State3";

        // Act & Assert
        vm.prank(FUSE_STATE_MANAGER_ROLE);
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInputLength.selector);
        _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
    }

    function test_AddFuseStates_Unauthorized() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](1);
        string[] memory fuseStateNames = new string[](1);

        fuseStateIds[0] = 1;
        fuseStateNames[0] = "State1";

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("FUSE_STATE_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
    }

    function test_AddFuseStates_EmptyInput() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](0);
        string[] memory fuseStateNames = new string[](0);

        // Act
        vm.startPrank(FUSE_STATE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true for empty input");
    }

    function test_AddFuseStates_EventEmitted() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](2);
        string[] memory fuseStateNames = new string[](2);

        fuseStateIds[0] = 1;
        fuseStateIds[1] = 2;

        fuseStateNames[0] = "State1";
        fuseStateNames[1] = "State2";

        // Act & Assert
        vm.startPrank(FUSE_STATE_MANAGER_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(1, "State1");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(2, "State2");
        bool result = _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddFuseStates_WithFuseStatusConstants() public {
        // Arrange
        uint16[] memory fuseStateIds = FuseStatus.getAllFuseStatuIds();
        string[] memory fuseStateNames = FuseStatus.getAllFuseStatusNames();

        (uint16[] memory fuseStatesIdsBefore, string[] memory fuseStatesNamesBefore) = _fuseWhitelist.getFuseStates();

        // Act
        vm.prank(FUSE_STATE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory fuseStatesIdsAfter, string[] memory fuseStatesNamesAfter) = _fuseWhitelist.getFuseStates();

        assertEq(fuseStatesIdsBefore.length, 0, "Fuses states should be empty");
        assertEq(fuseStatesIdsAfter.length, fuseStateIds.length, "Fuses states should be equal to the input");
        assertEq(fuseStatesNamesBefore.length, 0, "Fuses names should be empty");
        assertEq(fuseStatesNamesAfter.length, fuseStateNames.length, "Fuses names should be equal to the input");

        // Verify specific status values
        assertEq(fuseStatesIdsAfter[0], 0, "Default status ID should be 0");
        assertEq(fuseStatesIdsAfter[1], 1, "Active status ID should be 1");
        assertEq(fuseStatesIdsAfter[2], 2, "Deprecated status ID should be 2");
        assertEq(fuseStatesIdsAfter[3], 3, "Removed status ID should be 3");

        assertEq(fuseStatesNamesAfter[0], "Default", "Default status name should be 'Default'");
        assertEq(fuseStatesNamesAfter[1], "Active", "Active status name should be 'Active'");
        assertEq(fuseStatesNamesAfter[2], "Deprecated", "Deprecated status name should be 'Deprecated'");
        assertEq(fuseStatesNamesAfter[3], "Removed", "Removed status name should be 'Removed'");
    }

    function test_AddFuseStates_WithFuseStatusConstants_EventEmitted() public {
        // Arrange
        uint16[] memory fuseStateIds = FuseStatus.getAllFuseStatuIds();
        string[] memory fuseStateNames = FuseStatus.getAllFuseStatusNames();

        // Act & Assert
        vm.startPrank(FUSE_STATE_MANAGER_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(0, "Default");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(1, "Active");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(2, "Deprecated");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(3, "Removed");
        bool result = _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddMetadataTypes_Success() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](3);
        string[] memory metadataTypes = new string[](3);

        metadataIds[0] = 1;
        metadataIds[1] = 2;
        metadataIds[2] = 3;

        metadataTypes[0] = "Metadata1";
        metadataTypes[1] = "Metadata2";
        metadataTypes[2] = "Metadata3";

        (uint16[] memory metadataIdsBefore, string[] memory metadataTypesBefore) = _fuseWhitelist.getMetadataTypes();

        // Act
        vm.prank(FUSE_METADATA_MANAGER_ROLE);
        bool result = _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory metadataIdsAfter, string[] memory metadataTypesAfter) = _fuseWhitelist.getMetadataTypes();

        assertEq(metadataIdsBefore.length, 0, "Metadata types should be empty");
        assertEq(metadataIdsAfter.length, metadataIds.length, "Metadata types should be equal to the input");
        assertEq(metadataTypesBefore.length, 0, "Metadata names should be empty");
        assertEq(metadataTypesAfter.length, metadataTypes.length, "Metadata names should be equal to the input");
    }

    function test_AddMetadataTypes_InvalidInputLength() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](2);
        string[] memory metadataTypes = new string[](3);

        metadataIds[0] = 1;
        metadataIds[1] = 2;

        metadataTypes[0] = "Metadata1";
        metadataTypes[1] = "Metadata2";
        metadataTypes[2] = "Metadata3";

        // Act & Assert
        vm.prank(FUSE_METADATA_MANAGER_ROLE);
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInputLength.selector);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
    }

    function test_AddMetadataTypes_Unauthorized() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);

        metadataIds[0] = 1;
        metadataTypes[0] = "Metadata1";

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("FUSE_METADATA_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
    }

    function test_AddMetadataTypes_EmptyInput() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](0);
        string[] memory metadataTypes = new string[](0);

        // Act
        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        bool result = _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true for empty input");
    }

    function test_AddMetadataTypes_EventEmitted() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](2);
        string[] memory metadataTypes = new string[](2);

        metadataIds[0] = 1;
        metadataIds[1] = 2;

        metadataTypes[0] = "Metadata1";
        metadataTypes[1] = "Metadata2";

        // Act & Assert
        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(1, "Metadata1");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(2, "Metadata2");
        bool result = _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddFuseTypesAndStates_Success() public {
        // Arrange
        addFuseTypesAndStates();

        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 2;

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        // Act
        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Assert
        address[] memory fusesByType = _fuseWhitelist.getFusesByType(1);
        assertEq(fusesByType.length, 1, "Fuses by type should be equal to the input");
        assertEq(fusesByType[0], fuses[0], "Fuses by type should be equal to the input");

        fusesByType = _fuseWhitelist.getFusesByType(2);
        assertEq(fusesByType.length, 1, "Fuses by type should be equal to the input");
        assertEq(fusesByType[0], fuses[1], "Fuses by type should be equal to the input");

        (uint16 fuseState, uint16 fuseType, address fuseAddress, uint32 timestamp) = _fuseWhitelist.getFuseByAddress(
            fuses[0]
        );
        assertEq(fuseAddress, fuses[0], "Fuses by address should be equal to the input");
        assertEq(fuseState, 0, "Fuses by address should be equal to the input");
        assertEq(fuseType, 1, "Fuses by address should be equal to the input");

        (fuseState, fuseType, fuseAddress, timestamp) = _fuseWhitelist.getFuseByAddress(fuses[1]);
        assertEq(fuseAddress, fuses[1], "Fuses by address should be equal to the input");
        assertEq(fuseState, 0, "Fuses by address should be equal to the input");
        assertEq(fuseType, 2, "Fuses by address should be equal to the input");
    }

    function test_AddFuses_UnknownType() public {
        // Arrange
        addFuseTypesAndStates();

        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 3; // Unknown type

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        // Act & Assert
        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidFuseTypeId.selector, 3));
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();
    }

    function test_AddFuses_InvalidInputLength() public {
        // Arrange
        addFuseTypesAndStates();

        address[] memory fuses = new address[](2);
        fuses[0] = address(0x123);
        fuses[1] = address(0x456);

        uint16[] memory types = new uint16[](3); // Different length
        types[0] = 1;
        types[1] = 2;
        types[2] = 1;

        uint16[] memory states = new uint16[](3);
        states[0] = 0;
        states[1] = 0;
        states[2] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](3);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);
        deploymentTimestamps[2] = uint32(block.timestamp);

        // Act & Assert
        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInputLength.selector);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();
    }

    function test_UpdateFuseState_Success() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Verify initial state
        (uint16 fuseState, uint16 fuseTypeBefore, address fuseAddressBefore, uint32 timestamp) = _fuseWhitelist
            .getFuseByAddress(fuseAddress);
        assertEq(fuseState, 0, "Initial state should be 0");
        assertEq(fuseTypeBefore, fuseType, "Fuse type should be correct");
        assertEq(fuseAddressBefore, fuseAddress, "Fuse address should be correct");

        // Act
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        bool result = _fuseWhitelist.updateFuseState(fuseAddress, 1); // Update to Active state
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true");
        (fuseState, fuseTypeBefore, fuseAddressBefore, timestamp) = _fuseWhitelist.getFuseByAddress(fuseAddress);
        assertEq(fuseState, 1, "State should be updated to 1");
        assertEq(fuseTypeBefore, fuseType, "Fuse type should remain unchanged");
        assertEq(fuseAddressBefore, fuseAddress, "Fuse address should remain unchanged");
    }

    function test_UpdateFuseState_NonExistentFuse() public {
        // Arrange
        addFuseTypesAndStates();
        address nonExistentFuse = address(0x999);

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.FuseNotFound.selector, nonExistentFuse));
        _fuseWhitelist.updateFuseState(nonExistentFuse, 1);
        vm.stopPrank();
    }

    function test_UpdateFuseState_InvalidState() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidFuseState.selector, 10));
        _fuseWhitelist.updateFuseState(fuseAddress, 10);
        vm.stopPrank();
    }

    function test_UpdateFuseState_Unauthorized() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("UPDATE_FUSE_STATE_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.updateFuseState(fuseAddress, 1);
    }

    function test_UpdateFuseState_EventEmitted() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateUpdated(fuseAddress, 1, fuseType);
        bool result = _fuseWhitelist.updateFuseState(fuseAddress, 1);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_UpdateFuseMetadata_Success() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Add metadata type
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);
        metadataIds[0] = 1;
        metadataTypes[0] = "TestMetadata";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        // Prepare metadata
        bytes32[] memory metadata = new bytes32[](2);
        metadata[0] = keccak256("test1");
        metadata[1] = keccak256("test2");

        // Act
        vm.startPrank(UPDATE_FUSE_METADATA_ROLE);
        bool result = _fuseWhitelist.updateFuseMetadata(fuseAddress, 1, metadata);
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true");
    }

    function test_UpdateFuseMetadata_NonExistentFuse() public {
        // Arrange
        addFuseTypesAndStates();

        // Add metadata type
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);
        metadataIds[0] = 1;
        metadataTypes[0] = "TestMetadata";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        address nonExistentFuse = address(0x999);
        bytes32[] memory metadata = new bytes32[](1);
        metadata[0] = keccak256("test");

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_METADATA_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.FuseNotFound.selector, nonExistentFuse));
        _fuseWhitelist.updateFuseMetadata(nonExistentFuse, 1, metadata);
        vm.stopPrank();
    }

    function test_UpdateFuseMetadata_InvalidMetadataType() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        bytes32[] memory metadata = new bytes32[](1);
        metadata[0] = keccak256("test");

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_METADATA_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidMetadataType.selector, 10));
        _fuseWhitelist.updateFuseMetadata(fuseAddress, 10, metadata);
        vm.stopPrank();
    }

    function test_UpdateFuseMetadata_Unauthorized() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Add metadata type
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);
        metadataIds[0] = 1;
        metadataTypes[0] = "TestMetadata";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        bytes32[] memory metadata = new bytes32[](1);
        metadata[0] = keccak256("test");

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("UPDATE_FUSE_METADATA_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.updateFuseMetadata(fuseAddress, 1, metadata);
    }

    function test_UpdateFuseMetadata_EventEmitted() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = 0;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Add metadata type
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);
        metadataIds[0] = 1;
        metadataTypes[0] = "TestMetadata";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        bytes32[] memory metadata = new bytes32[](2);
        metadata[0] = keccak256("test1");
        metadata[1] = keccak256("test2");

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_METADATA_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseMetadataUpdated(fuseAddress, 1, metadata);
        bool result = _fuseWhitelist.updateFuseMetadata(fuseAddress, 1, metadata);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_GetFuseTypeDescription_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        string memory description = _fuseWhitelist.getFuseTypeDescription(1);

        // Assert
        assertEq(description, "Type1", "Fuse type description should match");
    }

    function test_GetFuseTypeDescription_NonExistentType() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        string memory description = _fuseWhitelist.getFuseTypeDescription(999);

        // Assert
        assertEq(description, "", "Non-existent fuse type should return empty string");
    }

    function test_GetFuseStates_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        (uint16[] memory statesIds, string[] memory statesNames) = _fuseWhitelist.getFuseStates();

        // Assert
        assertEq(statesIds.length, 3, "Should return 3 states");
        assertEq(statesNames.length, 3, "Should return 3 state names");

        // Verify IDs
        assertEq(statesIds[0], 0, "First state ID should be 0");
        assertEq(statesIds[1], 1, "Second state ID should be 1");
        assertEq(statesIds[2], 2, "Third state ID should be 2");

        // Verify names
        assertEq(statesNames[0], "Default", "First state name should be Default");
        assertEq(statesNames[1], "Active", "Second state name should be Active");
        assertEq(statesNames[2], "Inactive", "Third state name should be Inactive");
    }

    function test_GetFuseStates_Empty() public {
        // Act
        (uint16[] memory statesIds, string[] memory statesNames) = _fuseWhitelist.getFuseStates();

        // Assert
        assertEq(statesIds.length, 0, "Should return empty array of IDs");
        assertEq(statesNames.length, 0, "Should return empty array of names");
    }

    function test_GetFuseStateName_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        string memory description = _fuseWhitelist.getFuseStateName(1);

        // Assert
        assertEq(description, "Active", "Fuse state description should match");
    }

    function test_GetFuseStateName_NonExistentState() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        string memory description = _fuseWhitelist.getFuseStateName(999);

        // Assert
        assertEq(description, "", "Non-existent fuse state should return empty string");
    }

    function test_GetMetadataTypes_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Add metadata types
        uint16[] memory metadataIds = new uint16[](3);
        string[] memory metadataTypes = new string[](3);

        metadataIds[0] = 1;
        metadataIds[1] = 2;
        metadataIds[2] = 3;

        metadataTypes[0] = "Metadata1";
        metadataTypes[1] = "Metadata2";
        metadataTypes[2] = "Metadata3";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        // Act
        (uint16[] memory ids, string[] memory types) = _fuseWhitelist.getMetadataTypes();

        // Assert
        assertEq(ids.length, 3, "Should return 3 metadata types");
        assertEq(types.length, 3, "Should return 3 metadata type names");

        // Verify IDs
        assertEq(ids[0], 1, "First metadata ID should be 1");
        assertEq(ids[1], 2, "Second metadata ID should be 2");
        assertEq(ids[2], 3, "Third metadata ID should be 3");

        // Verify names
        assertEq(types[0], "Metadata1", "First metadata name should be Metadata1");
        assertEq(types[1], "Metadata2", "Second metadata name should be Metadata2");
        assertEq(types[2], "Metadata3", "Third metadata name should be Metadata3");
    }

    function test_GetMetadataTypes_Empty() public {
        // Act
        (uint16[] memory ids, string[] memory types) = _fuseWhitelist.getMetadataTypes();

        // Assert
        assertEq(ids.length, 0, "Should return empty array of IDs");
        assertEq(types.length, 0, "Should return empty array of names");
    }

    function test_GetMetadataType_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Add metadata type
        uint16[] memory metadataIds = new uint16[](1);
        string[] memory metadataTypes = new string[](1);
        metadataIds[0] = 1;
        metadataTypes[0] = "TestMetadata";

        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        // Act
        string memory description = _fuseWhitelist.getMetadataType(1);

        // Assert
        assertEq(description, "TestMetadata", "Metadata type description should match");
    }

    function test_GetMetadataType_NonExistentType() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        string memory description = _fuseWhitelist.getMetadataType(999);

        // Assert
        assertEq(description, "", "Non-existent metadata type should return empty string");
    }

    function test_GetFusesByType_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses
        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 1; // Both fuses are of type 1

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        address[] memory fusesByType = _fuseWhitelist.getFusesByType(1);

        // Assert
        assertEq(fusesByType.length, 2, "Should return 2 fuses");
        assertEq(fusesByType[0], fuses[0], "First fuse should match");
        assertEq(fusesByType[1], fuses[1], "Second fuse should match");
    }

    function test_GetFusesByType_Empty() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        address[] memory fusesByType = _fuseWhitelist.getFusesByType(1);

        // Assert
        assertEq(fusesByType.length, 0, "Should return empty array");
    }

    function test_GetFusesByType_NonExistentType() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        address[] memory fusesByType = _fuseWhitelist.getFusesByType(999);

        // Assert
        assertEq(fusesByType.length, 0, "Should return empty array for non-existent type");
    }

    function test_GetFuseByAddress_Success() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(new Erc4626SupplyFuse(1));
        uint16 fuseType = 1;
        uint16 fuseState = 0;

        // Add fuse
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;
        uint16[] memory states = new uint16[](1);
        states[0] = fuseState;
        uint32[] memory deploymentTimestamps = new uint32[](1);
        deploymentTimestamps[0] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        (uint16 state, uint16 typeFuse, address address_, uint32 timestamp) = _fuseWhitelist.getFuseByAddress(
            fuseAddress
        );

        // Assert
        assertEq(state, fuseState, "Fuse state should match");
        assertEq(typeFuse, fuseType, "Fuse type should match");
        assertEq(address_, fuseAddress, "Fuse address should match");
        assertTrue(timestamp > 0, "Timestamp should be set");
    }

    function test_GetFuseByAddress_NonExistentFuse() public {
        // Arrange
        addFuseTypesAndStates();
        address nonExistentFuse = address(0x999);

        // Act
        (uint16 state, uint16 typeFuse, address address_, uint32 timestamp) = _fuseWhitelist.getFuseByAddress(
            nonExistentFuse
        );

        // Assert
        assertEq(state, 0, "Non-existent fuse should have state 0");
        assertEq(typeFuse, 0, "Non-existent fuse should have type 0");
        assertEq(address_, address(0), "Non-existent fuse should have zero address");
        assertEq(timestamp, 0, "Non-existent fuse should have timestamp 0");
    }

    function test_GetFusesByMarketId_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses with different market IDs
        address[] memory fuses = new address[](3);
        fuses[0] = address(new Erc4626SupplyFuse(1)); // Market ID 1
        fuses[1] = address(new Erc4626SupplyFuse(1)); // Market ID 1
        fuses[2] = address(new Erc4626SupplyFuse(2)); // Market ID 2

        uint16[] memory types = new uint16[](3);
        types[0] = 1;
        types[1] = 1;
        types[2] = 2;

        uint16[] memory states = new uint16[](3);
        states[0] = 0;
        states[1] = 0;
        states[2] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](3);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);
        deploymentTimestamps[2] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        address[] memory fusesByMarketId = _fuseWhitelist.getFusesByMarketId(1);

        // Assert
        assertEq(fusesByMarketId.length, 2, "Should return 2 fuses for market ID 1");
        assertEq(fusesByMarketId[0], fuses[0], "First fuse should match");
        assertEq(fusesByMarketId[1], fuses[1], "Second fuse should match");
    }

    function test_GetFusesByMarketId_Empty() public {
        // Arrange
        addFuseTypesAndStates();

        // Act
        address[] memory fusesByMarketId = _fuseWhitelist.getFusesByMarketId(1);

        // Assert
        assertEq(fusesByMarketId.length, 0, "Should return empty array for market ID 1");
    }

    function test_GetFusesByMarketId_NonExistentMarket() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses
        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 2;

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        address[] memory fusesByMarketId = _fuseWhitelist.getFusesByMarketId(999);

        // Assert
        assertEq(fusesByMarketId.length, 0, "Should return empty array for non-existent market ID");
    }

    function test_GetFusesByTypeAndMarketIdAndStatus_Success() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses with different combinations
        address[] memory fuses = new address[](4);
        fuses[0] = address(new Erc4626SupplyFuse(1)); // Market ID 1, Type 1, State 0
        fuses[1] = address(new Erc4626SupplyFuse(1)); // Market ID 1, Type 1, State 1
        fuses[2] = address(new Erc4626SupplyFuse(2)); // Market ID 2, Type 2, State 0
        fuses[3] = address(new Erc4626SupplyFuse(1)); // Market ID 1, Type 1, State 2

        uint16[] memory types = new uint16[](4);
        types[0] = 1;
        types[1] = 1;
        types[2] = 2;
        types[3] = 1;

        uint16[] memory states = new uint16[](4);
        states[0] = 0;
        states[1] = 1;
        states[2] = 0;
        states[3] = 2;

        uint32[] memory deploymentTimestamps = new uint32[](4);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);
        deploymentTimestamps[2] = uint32(block.timestamp);
        deploymentTimestamps[3] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act - Test different combinations
        address[] memory result1 = _fuseWhitelist.getFusesByTypeAndMarketIdAndStatus(1, 1, 0);
        address[] memory result2 = _fuseWhitelist.getFusesByTypeAndMarketIdAndStatus(1, 1, 1);
        address[] memory result3 = _fuseWhitelist.getFusesByTypeAndMarketIdAndStatus(2, 2, 0);

        // Assert
        // Test 1: Market ID 1, Type 1, State 0
        assertEq(result1.length, 1, "Should return 1 fuse for Market 1, Type 1, State 0");
        assertEq(result1[0], fuses[0], "Should return correct fuse");

        // Test 2: Market ID 1, Type 1, State 1
        assertEq(result2.length, 1, "Should return 1 fuse for Market 1, Type 1, State 1");
        assertEq(result2[0], fuses[1], "Should return correct fuse");

        // Test 3: Market ID 2, Type 2, State 0
        assertEq(result3.length, 1, "Should return 1 fuse for Market 2, Type 2, State 0");
        assertEq(result3[0], fuses[2], "Should return correct fuse");
    }

    function test_GetFusesByTypeAndMarketIdAndStatus_Empty() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses
        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 2;

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        address[] memory result = _fuseWhitelist.getFusesByTypeAndMarketIdAndStatus(1, 1, 1);

        // Assert
        assertEq(result.length, 0, "Should return empty array when no matches found");
    }

    function test_GetFusesByTypeAndMarketIdAndStatus_NonExistentCombination() public {
        // Arrange
        addFuseTypesAndStates();

        // Add fuses
        address[] memory fuses = new address[](2);
        fuses[0] = address(new Erc4626SupplyFuse(1));
        fuses[1] = address(new Erc4626SupplyFuse(2));

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 2;

        uint16[] memory states = new uint16[](2);
        states[0] = 0;
        states[1] = 0;

        uint32[] memory deploymentTimestamps = new uint32[](2);
        deploymentTimestamps[0] = uint32(block.timestamp);
        deploymentTimestamps[1] = uint32(block.timestamp);

        vm.startPrank(ADD_FUSE_MANAGER_ROLE);
        _fuseWhitelist.addFuses(fuses, types, states, deploymentTimestamps);
        vm.stopPrank();

        // Act
        address[] memory result = _fuseWhitelist.getFusesByTypeAndMarketIdAndStatus(999, 999, 999);

        // Assert
        assertEq(result.length, 0, "Should return empty array for non-existent combination");
    }

    function test_AddAllFuseTypes_Success() public {
        // Arrange
        uint16[] memory fuseTypeIds = FuseTypes.getAllFuseId();
        string[] memory fuseTypeNames = FuseTypes.getAllFuseName();

        (uint16[] memory fuseTypesIdsBefore, string[] memory fuseTypesNamesBefore) = _fuseWhitelist.getFuseTypes();

        // Act
        vm.startPrank(FUSE_TYPE_MANAGER_ROLE);
        bool result = _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        vm.stopPrank();

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory fuseTypesIdsAfter, string[] memory fuseTypesNamesAfter) = _fuseWhitelist.getFuseTypes();

        assertEq(fuseTypesIdsBefore.length, 0, "Fuses types should be empty before");
        assertEq(fuseTypesIdsAfter.length, fuseTypeIds.length, "Fuses types should be equal to the input");
        assertEq(fuseTypesNamesBefore.length, 0, "Fuses names should be empty before");
        assertEq(fuseTypesNamesAfter.length, fuseTypeNames.length, "Fuses names should be equal to the input");

        // Verify each fuse type was added correctly
        for (uint256 i = 0; i < fuseTypeIds.length; i++) {
            string memory description = _fuseWhitelist.getFuseTypeDescription(fuseTypeIds[i]);
            assertEq(description, fuseTypeNames[i], "Fuse type description should match");
        }
    }

    function test_AddAllFuseTypes_EventEmitted() public {
        // Arrange
        uint16[] memory fuseTypeIds = FuseTypes.getAllFuseId();
        string[] memory fuseTypeNames = FuseTypes.getAllFuseName();

        // Act & Assert
        vm.startPrank(FUSE_TYPE_MANAGER_ROLE);
        for (uint256 i = 0; i < fuseTypeIds.length; i++) {
            vm.expectEmit(true, true, true, true);
            emit FuseWhitelistLib.FuseTypeAdded(fuseTypeIds[i], fuseTypeNames[i]);
        }
        bool result = _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddMetadataTypes_WithFuseMetadataTypesConstants() public {
        // Arrange
        uint16[] memory metadataIds = FuseMetadataTypes.getAllFuseMetadataTypeIds();
        string[] memory metadataTypes = FuseMetadataTypes.getAllFuseMetadataTypeNames();

        (uint16[] memory metadataIdsBefore, string[] memory metadataTypesBefore) = _fuseWhitelist.getMetadataTypes();

        // Act
        vm.prank(FUSE_METADATA_MANAGER_ROLE);
        bool result = _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);

        // Assert
        assertTrue(result, "Function should return true");
        (uint16[] memory metadataIdsAfter, string[] memory metadataTypesAfter) = _fuseWhitelist.getMetadataTypes();

        assertEq(metadataIdsBefore.length, 0, "Metadata types should be empty");
        assertEq(metadataIdsAfter.length, metadataIds.length, "Metadata types should be equal to the input");
        assertEq(metadataTypesBefore.length, 0, "Metadata names should be empty");
        assertEq(metadataTypesAfter.length, metadataTypes.length, "Metadata names should be equal to the input");

        // Verify specific metadata type values
        assertEq(metadataIdsAfter[0], 0, "Audit Status ID should be 0");
        assertEq(metadataIdsAfter[1], 1, "Substrate Info ID should be 1");
        assertEq(metadataIdsAfter[2], 2, "Category Info ID should be 2");
        assertEq(metadataIdsAfter[3], 3, "Abi Version ID should be 3");

        assertEq(metadataTypesAfter[0], "Audit_Status", "Audit Status name should be 'Audit_Status'");
        assertEq(metadataTypesAfter[1], "Substrate_Info", "Substrate Info name should be 'Substrate_Info'");
        assertEq(metadataTypesAfter[2], "Category_Info", "Category Info name should be 'Category_Info'");
        assertEq(metadataTypesAfter[3], "Abi_Version", "Abi Version name should be 'Abi_Version'");
    }

    function test_AddMetadataTypes_WithFuseMetadataTypesConstants_EventEmitted() public {
        // Arrange
        uint16[] memory metadataIds = FuseMetadataTypes.getAllFuseMetadataTypeIds();
        string[] memory metadataTypes = FuseMetadataTypes.getAllFuseMetadataTypeNames();

        // Act & Assert
        vm.startPrank(FUSE_METADATA_MANAGER_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(0, "Audit_Status");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(1, "Substrate_Info");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(2, "Category_Info");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.MetadataTypeAdded(3, "Abi_Version");
        bool result = _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
    }

    function test_AddMetadataTypes_WithFuseMetadataTypesConstants_Unauthorized() public {
        // Arrange
        uint16[] memory metadataIds = FuseMetadataTypes.getAllFuseMetadataTypeIds();
        string[] memory metadataTypes = FuseMetadataTypes.getAllFuseMetadataTypeNames();

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("FUSE_METADATA_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
    }

    function addFuseTypesAndStates() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](2);
        string[] memory fuseTypeNames = new string[](2);

        fuseTypeIds[0] = 1;
        fuseTypeIds[1] = 2;

        fuseTypeNames[0] = "Type1";
        fuseTypeNames[1] = "Type2";

        uint16[] memory fuseStateIds = new uint16[](3);
        string[] memory fuseStateNames = new string[](3);

        fuseStateIds[0] = 0;
        fuseStateIds[1] = 1;
        fuseStateIds[2] = 2;

        fuseStateNames[0] = "Default";
        fuseStateNames[1] = "Active";
        fuseStateNames[2] = "Inactive";

        // Act
        vm.startPrank(FUSE_TYPE_MANAGER_ROLE);
        _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
        vm.stopPrank();
    }
}
