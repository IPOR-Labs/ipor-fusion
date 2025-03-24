// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {FuseWhitelist} from "../../../contracts/fuses/whitelist/FuseWhitelist.sol";
import {FuseWhitelistLib} from "../../../contracts/fuses/whitelist/FuseWhitelistLib.sol";
import {TestAddresses} from "../../test_helpers/TestAddresses.sol";

contract FuseWhitelistTest is Test {
    FuseWhitelist private _fuseWhitelist;
    address ADMIN = TestAddresses.ADMIN;
    address CONFIGURATION_MANAGER = TestAddresses.ATOMIST;
    address ADD_FUSE_MENAGER = TestAddresses.FUSE_MANAGER;
    address UPDATE_FUSE_STATE_ROLE = TestAddresses.FUSE_MANAGER;
    address UPDATE_FUSE_METADATA_ROLE = TestAddresses.FUSE_MANAGER;

    function setUp() public {
        // Setup code will be added here
        _fuseWhitelist = FuseWhitelist(
            address(
                new ERC1967Proxy(address(new FuseWhitelist()), abi.encodeWithSignature("initialize(address)", ADMIN))
            )
        );

        vm.startPrank(ADMIN);
        _fuseWhitelist.grantRole(_fuseWhitelist.CONFIGURATION_MANAGER_ROLE(), CONFIGURATION_MANAGER);
        _fuseWhitelist.grantRole(_fuseWhitelist.ADD_FUSE_MENAGER_ROLE(), ADD_FUSE_MENAGER);
        _fuseWhitelist.grantRole(_fuseWhitelist.UPDATE_FUSE_STATE_ROLE(), UPDATE_FUSE_STATE_ROLE);
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
        vm.prank(CONFIGURATION_MANAGER);
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
        vm.prank(CONFIGURATION_MANAGER);
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
                keccak256("CONFIGURATION_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
    }

    function test_AddFuseTypes_EmptyInput() public {
        // Arrange
        uint16[] memory fuseTypeIds = new uint16[](0);
        string[] memory fuseTypeNames = new string[](0);

        // Act
        vm.startPrank(CONFIGURATION_MANAGER);
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
        vm.startPrank(CONFIGURATION_MANAGER);
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
        vm.prank(CONFIGURATION_MANAGER);
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
        vm.prank(CONFIGURATION_MANAGER);
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
                keccak256("CONFIGURATION_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
    }

    function test_AddFuseStates_EmptyInput() public {
        // Arrange
        uint16[] memory fuseStateIds = new uint16[](0);
        string[] memory fuseStateNames = new string[](0);

        // Act
        vm.startPrank(CONFIGURATION_MANAGER);
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
        vm.startPrank(CONFIGURATION_MANAGER);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(1, "State1");
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateAdded(2, "State2");
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
        vm.prank(CONFIGURATION_MANAGER);
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
        vm.prank(CONFIGURATION_MANAGER);
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
                keccak256("CONFIGURATION_MANAGER_ROLE")
            )
        );
        _fuseWhitelist.addMetadataTypes(metadataIds, metadataTypes);
    }

    function test_AddMetadataTypes_EmptyInput() public {
        // Arrange
        uint16[] memory metadataIds = new uint16[](0);
        string[] memory metadataTypes = new string[](0);

        // Act
        vm.startPrank(CONFIGURATION_MANAGER);
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
        vm.startPrank(CONFIGURATION_MANAGER);
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
        fuses[0] = address(0x123);
        fuses[1] = address(0x456);

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 2;

        // Act
        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();

        // Assert
        address[] memory fusesByType = _fuseWhitelist.getFuseByType(1);
        assertEq(fusesByType.length, 1, "Fuses by type should be equal to the input");
        assertEq(fusesByType[0], fuses[0], "Fuses by type should be equal to the input");

        fusesByType = _fuseWhitelist.getFuseByType(2);
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
        fuses[0] = address(0x123);
        fuses[1] = address(0x456);

        uint16[] memory types = new uint16[](2);
        types[0] = 1;
        types[1] = 3; // Unknown type

        // Act & Assert
        vm.startPrank(ADD_FUSE_MENAGER);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidFuseTypeId.selector, 3));
        _fuseWhitelist.addFuses(fuses, types);
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

        // Act & Assert
        vm.startPrank(ADD_FUSE_MENAGER);
        vm.expectRevert(FuseWhitelist.FuseWhitelistInvalidInputLength.selector);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();
    }

    function test_UpdateFuseState_Success() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(0x123);
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;

        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
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

        address fuseAddress = address(0x123);
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;

        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidFuseState.selector, 10));
        _fuseWhitelist.updateFuseState(fuseAddress, 10);
        vm.stopPrank();
    }

    function test_UpdateFuseState_UnableToSetupDefaultState() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(0x123);
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;

        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectRevert(abi.encodeWithSelector(FuseWhitelistLib.InvalidFuseState.selector, 0));
        _fuseWhitelist.updateFuseState(fuseAddress, 0);
        vm.stopPrank();
    }

    function test_UpdateFuseState_Unauthorized() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(0x123);
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;

        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();

        // Act & Assert
        vm.prank(address(0x123)); // Random address without role
        vm.expectRevert(
            abi.encodeWithSelector(
                bytes4(keccak256("AccessControlUnauthorizedAccount(address,bytes32)")),
                address(0x123),
                keccak256("UPDATE_FUSE_STATE_ROLE")
            )
        );
        _fuseWhitelist.updateFuseState(fuseAddress, 1);
    }

    function test_UpdateFuseState_EventEmitted() public {
        // Arrange
        addFuseTypesAndStates();

        address fuseAddress = address(0x123);
        uint16 fuseType = 1;

        // Add fuse first
        address[] memory fuses = new address[](1);
        fuses[0] = fuseAddress;
        uint16[] memory types = new uint16[](1);
        types[0] = fuseType;

        vm.startPrank(ADD_FUSE_MENAGER);
        _fuseWhitelist.addFuses(fuses, types);
        vm.stopPrank();

        // Act & Assert
        vm.startPrank(UPDATE_FUSE_STATE_ROLE);
        vm.expectEmit(true, true, true, true);
        emit FuseWhitelistLib.FuseStateUpdated(fuseAddress, 1, fuseType);
        bool result = _fuseWhitelist.updateFuseState(fuseAddress, 1);
        vm.stopPrank();

        assertTrue(result, "Function should return true");
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
        vm.startPrank(CONFIGURATION_MANAGER);
        _fuseWhitelist.addFuseTypes(fuseTypeIds, fuseTypeNames);
        _fuseWhitelist.addFuseStates(fuseStateIds, fuseStateNames);
        vm.stopPrank();
    }
}
