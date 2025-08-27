// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";

/// @title FuseWhitelistLib
/// @notice Library for managing fuse whitelisting and configuration
/// @dev Implements storage patterns and access control mechanisms for fuse management

/// @notice Structure for storing fuse types
/// @param fusesTypes Mapping of fuse IDs to their type descriptions
/// @param fusesIds Array of all registered fuse type IDs
struct FusesTypes {
    mapping(uint16 fuseId => string fuseType) fusesTypes;
    uint16[] fusesIds;
}

/// @notice Structure for storing fuse states
/// @param fusesStates Mapping of state IDs to their descriptions
/// @param statesIds Array of all registered state IDs
struct FusesStates {
    mapping(uint16 stateId => string fuseState) fusesStates;
    uint16[] statesIds;
}

/// @notice Structure for storing metadata types
/// @param metadataTypes Mapping of metadata IDs to their descriptions
/// @param metadataIds Array of all registered metadata type IDs
struct MetadataTypes {
    mapping(uint16 metadataId => string metadataType) metadataTypes;
    uint16[] metadataIds;
}

/// @notice Structure for storing fuses by type
/// @param fusesByType Mapping of fuse type IDs to arrays of fuse addresses
struct FuseListsByType {
    mapping(uint16 fuseTypeId => address[] fuses) fusesByType;
}

/// @notice Structure for storing detailed fuse information
/// @param fuseState Current state of the fuse
/// @param fuseType Type of the fuse
/// @param fuseAddress Address of the fuse contract
/// @param timestamp When the fuse was added
/// @param metadata Mapping of metadata IDs to their values
/// @param metadataIds Array of all metadata IDs associated with the fuse
struct FuseInfo {
    uint16 fuseState;
    uint16 fuseType;
    address fuseAddress;
    uint32 timestamp;
    mapping(uint256 metadataId => bytes32[] metadata) metadata;
    uint256[] metadataIds;
}

/// @notice Structure for storing fuses by address
/// @param fusesByAddress Mapping of fuse addresses to their detailed information
struct FuseListByAddress {
    mapping(address fuseAddress => FuseInfo fuseInfo) fusesByAddress;
}

/// @notice Structure for storing fuses by market ID
/// @param fusesByMarketId Mapping of market IDs to arrays of fuse addresses
struct FuseInfoByMarketId {
    mapping(uint256 marketId => address[] fuses) fusesByMarketId;
}

library FuseWhitelistLib {
    /// @notice Thrown when attempting to add an empty fuse type
    error EmptyFuseType();
    /// @notice Thrown when attempting to add a fuse type that already exists
    error FuseTypeAlreadyExists(uint256 fuseId);
    /// @notice Thrown when attempting to add an empty fuse state
    error EmptyFuseState();
    /// @notice Thrown when attempting to add a fuse state that already exists
    error FuseStateAlreadyExists(uint256 stateId);
    /// @notice Thrown when attempting to add an empty metadata type
    error EmptyMetadataType();
    /// @notice Thrown when attempting to add a metadata type that already exists
    error MetadataTypeAlreadyExists(uint256 metadataId);
    /// @notice Thrown when attempting to add a fuse to a list with an invalid type ID
    error InvalidFuseTypeId(uint256 fuseTypeId);
    /// @notice Thrown when attempting to add a zero address fuse
    error ZeroAddressFuse();
    /// @notice Thrown when attempting to add a fuse info with an invalid type ID
    error InvalidFuseTypeForInfo(uint256 fuseTypeId);
    /// @notice Thrown when attempting to add a fuse info with zero address
    error ZeroAddressFuseInfo();
    /// @notice Thrown when attempting to update a fuse state with an invalid state ID
    error InvalidFuseState(uint16 fuseState);
    /// @notice Thrown when attempting to add metadata with an invalid metadata type ID
    error InvalidMetadataType(uint256 metadataId);
    /// @notice Thrown when attempting to add metadata to a non-existent fuse
    error FuseNotFound(address fuseAddress);
    /// @notice Thrown when attempting to add a fuse info with a zero deployment timestamp
    error ZeroDeploymentTimestamp();

    /// @notice Emitted when a new fuse type is added
    /// @param fuseId The ID of the added fuse type
    /// @param fuseType The description of the fuse type
    event FuseTypeAdded(uint16 fuseId, string fuseType);
    /// @notice Emitted when a new fuse state is added
    /// @param stateId The ID of the added state
    /// @param fuseState The description of the state
    event FuseStateAdded(uint16 stateId, string fuseState);
    /// @notice Emitted when a new metadata type is added
    /// @param metadataId The ID of the added metadata type
    /// @param metadataType The description of the metadata type
    event MetadataTypeAdded(uint16 metadataId, string metadataType);
    /// @notice Emitted when a fuse is added to a type list
    /// @param fuseTypeId The ID of the fuse type
    /// @param fuseAddress The address of the added fuse
    event FuseAddedToListByType(uint16 fuseTypeId, address fuseAddress);
    /// @notice Emitted when fuse metadata is updated
    /// @param fuseAddress The address of the updated fuse
    /// @param metadataId The ID of the updated metadata
    /// @param metadata The new metadata values
    event FuseMetadataUpdated(address fuseAddress, uint256 metadataId, bytes32[] metadata);
    /// @notice Emitted when a fuse state is updated
    /// @param fuseAddress The address of the updated fuse
    /// @param fuseState The new state of the fuse
    /// @param fuseType The type of the fuse
    event FuseStateUpdated(address fuseAddress, uint16 fuseState, uint16 fuseType);
    /// @notice Emitted when a fuse is added to a market ID list
    /// @param fuseAddress The address of the added fuse
    /// @param marketId The market ID the fuse was added to
    event FuseAddedToMarketId(address fuseAddress, uint256 marketId);
    /// @notice Emitted when fuse info is added
    /// @param fuseAddress The address of the added fuse
    /// @param fuseType The type of the fuse
    /// @param timestamp When the fuse was added
    event FuseInfoAdded(address fuseAddress, uint16 fuseType, uint32 timestamp);

    /// @notice Storage slot for FusesTypes struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.fuseTypes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSES_TYPES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;
    /// @notice Storage slot for FusesStates struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.fuseStates")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSES_STATES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd01;
    /// @notice Storage slot for FuseInfo struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.fuseInfo")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSE_INFO = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd02;
    /// @notice Storage slot for FuseListsByType struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.fuseListsByType")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSE_LISTS_BY_TYPE = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd04;
    /// @notice Storage slot for FuseInfoByMarketId struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.fuseInfoByMarketId")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FUSE_INFO_BY_MARKET_ID =
        0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd03;
    /// @notice Storage slot for MetadataTypes struct
    /// @dev Storage slot calculation:
    /// keccak256(abi.encode(uint256(keccak256("io.ipor.whitelists.metadataTypes")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant METADATA_TYPES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd05;

    /// @notice Adds a new fuse type to the system
    /// @param fuseId_ The unique identifier for the fuse type
    /// @param fuseTypeId_ The descriptive name of the fuse type
    /// @dev Reverts if:
    /// - fuseTypeId_ is empty
    /// - fuseId_ already exists
    function addFuseType(uint16 fuseId_, string calldata fuseTypeId_) internal {
        if (bytes(fuseTypeId_).length == 0) {
            revert EmptyFuseType();
        }

        FusesTypes storage fusesTypes = _getFusesTypesSlot();
        if (bytes(fusesTypes.fusesTypes[fuseId_]).length != 0) {
            revert FuseTypeAlreadyExists(fuseId_);
        }

        fusesTypes.fusesTypes[fuseId_] = fuseTypeId_;
        fusesTypes.fusesIds.push(fuseId_);

        emit FuseTypeAdded(fuseId_, fuseTypeId_);
    }

    /// @notice Retrieves all registered fuse types
    /// @return fuseTypesIds Array of fuse type IDs
    /// @return fuseTypesNames Array of fuse type descriptions
    function getFuseTypes() internal view returns (uint16[] memory fuseTypesIds, string[] memory fuseTypesNames) {
        FusesTypes storage fusesTypes = _getFusesTypesSlot();
        fuseTypesIds = fusesTypes.fusesIds;

        uint256 length = fusesTypes.fusesIds.length;
        fuseTypesNames = new string[](length);
        for (uint256 i; i < length; ++i) {
            fuseTypesNames[i] = fusesTypes.fusesTypes[fuseTypesIds[i]];
        }
        return (fuseTypesIds, fuseTypesNames);
    }

    /// @notice Retrieves the description of a specific fuse type
    /// @param fuseTypeId_ The ID of the fuse type to query
    /// @return The description string of the fuse type
    function getFuseTypeDescription(uint16 fuseTypeId_) internal view returns (string memory) {
        return _getFusesTypesSlot().fusesTypes[fuseTypeId_];
    }

    /// @notice Adds a new fuse state to the system
    /// @param stateId_ The unique identifier for the state
    /// @param fuseStateName_ The descriptive name of the state
    /// @dev Reverts if:
    /// - fuseStateName_ is empty
    /// - stateId_ already exists
    function addFuseState(uint16 stateId_, string calldata fuseStateName_) internal {
        if (bytes(fuseStateName_).length == 0) {
            revert EmptyFuseState();
        }

        FusesStates storage fusesStates = _getFusesStatesSlot();
        if (bytes(fusesStates.fusesStates[stateId_]).length != 0) {
            revert FuseStateAlreadyExists(stateId_);
        }

        fusesStates.fusesStates[stateId_] = fuseStateName_;
        fusesStates.statesIds.push(stateId_);

        emit FuseStateAdded(stateId_, fuseStateName_);
    }

    /// @notice Retrieves all registered fuse states
    /// @return fuseStateIds Array of state IDs
    /// @return fuseStateNames Array of state descriptions
    function getFuseStates() internal view returns (uint16[] memory fuseStateIds, string[] memory fuseStateNames) {
        FusesStates storage fusesStates = _getFusesStatesSlot();
        fuseStateIds = fusesStates.statesIds;

        uint256 length = fusesStates.statesIds.length;
        fuseStateNames = new string[](length);
        for (uint256 i; i < length; ++i) {
            fuseStateNames[i] = fusesStates.fusesStates[fuseStateIds[i]];
        }
        return (fuseStateIds, fuseStateNames);
    }

    /// @notice Retrieves the description of a specific fuse state
    /// @param fuseStateId_ The ID of the state to query
    /// @return The description string of the state
    function getFuseStateName(uint16 fuseStateId_) internal view returns (string memory) {
        return _getFusesStatesSlot().fusesStates[fuseStateId_];
    }

    /// @notice Adds a new metadata type to the system
    /// @param metadataId_ The unique identifier for the metadata type
    /// @param metadataType_ The descriptive name of the metadata type
    /// @dev Reverts if:
    /// - metadataType_ is empty
    /// - metadataId_ already exists
    function addMetadataType(uint16 metadataId_, string calldata metadataType_) internal {
        if (bytes(metadataType_).length == 0) {
            revert EmptyMetadataType();
        }

        MetadataTypes storage metadataTypes = _getMetadataTypesSlot();
        if (bytes(metadataTypes.metadataTypes[metadataId_]).length != 0) {
            revert MetadataTypeAlreadyExists(metadataId_);
        }

        metadataTypes.metadataTypes[metadataId_] = metadataType_;
        metadataTypes.metadataIds.push(metadataId_);

        emit MetadataTypeAdded(metadataId_, metadataType_);
    }

    /// @notice Retrieves all registered metadata types
    /// @return metadataIds Array of metadata type IDs
    /// @return metadataTypes Array of metadata type descriptions
    function getMetadataTypes() internal view returns (uint16[] memory metadataIds, string[] memory metadataTypes) {
        MetadataTypes storage metadataTypesStorage = _getMetadataTypesSlot();
        metadataIds = metadataTypesStorage.metadataIds;

        uint256 length = metadataTypesStorage.metadataIds.length;
        metadataTypes = new string[](length);
        for (uint256 i; i < length; ++i) {
            metadataTypes[i] = metadataTypesStorage.metadataTypes[metadataIds[i]];
        }
        return (metadataIds, metadataTypes);
    }

    /// @notice Retrieves the description of a specific metadata type
    /// @param metadataId_ The ID of the metadata type to query
    /// @return The description string of the metadata type
    function getMetadataType(uint16 metadataId_) internal view returns (string memory) {
        return _getMetadataTypesSlot().metadataTypes[metadataId_];
    }

    /// @notice Adds a fuse to a type-specific list
    /// @param fuseTypeId_ The ID of the fuse type
    /// @param fuse_ The address of the fuse to add
    /// @dev Reverts if:
    /// - fuse_ is zero address
    /// - fuseTypeId_ is invalid
    function addFuseToListByType(uint16 fuseTypeId_, address fuse_) internal {
        if (fuse_ == address(0)) {
            revert ZeroAddressFuse();
        }

        FuseListsByType storage fuseListsByType = _getFuseListsByTypeSlot();
        FusesTypes storage fusesTypes = _getFusesTypesSlot();

        if (bytes(fusesTypes.fusesTypes[fuseTypeId_]).length == 0) {
            revert InvalidFuseTypeId(fuseTypeId_);
        }

        fuseListsByType.fusesByType[fuseTypeId_].push(fuse_);
        emit FuseAddedToListByType(fuseTypeId_, fuse_);
    }

    /// @notice Adds basic information about a fuse
    /// @param fuseType_ The type ID of the fuse
    /// @param fuseAddress_ The address of the fuse
    /// @param deploymentTimestamp_ The timestamp of the fuse deployment
    /// @dev Reverts if:
    /// - fuseAddress_ is zero address
    /// - fuseType_ is invalid
    function addFuseInfo(uint16 fuseType_, address fuseAddress_, uint32 deploymentTimestamp_) internal {
        if (fuseAddress_ == address(0)) {
            revert ZeroAddressFuseInfo();
        }
        if (deploymentTimestamp_ == 0) {
            revert ZeroDeploymentTimestamp();
        }

        FuseListByAddress storage fuseInfoByAddress = _getFuseListByAddressSlot();
        FusesTypes storage fusesTypes = _getFusesTypesSlot();

        if (bytes(fusesTypes.fusesTypes[fuseType_]).length == 0) {
            revert InvalidFuseTypeForInfo(fuseType_);
        }

        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseType = fuseType_;
        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress = fuseAddress_;
        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseState = 0;
        fuseInfoByAddress.fusesByAddress[fuseAddress_].timestamp = deploymentTimestamp_;

        emit FuseInfoAdded(fuseAddress_, fuseType_, deploymentTimestamp_);
    }

    /// @notice Updates the state of a fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param fuseState_ The new state ID
    /// @dev Reverts if:
    /// - fuseState_ is invalid
    /// - fuseAddress_ is not found
    function updateFuseState(address fuseAddress_, uint16 fuseState_) internal {
        FusesStates storage fusesStates = _getFusesStatesSlot();

        if (bytes(fusesStates.fusesStates[fuseState_]).length == 0) {
            revert InvalidFuseState(fuseState_);
        }

        FuseInfo storage fuseInfo = _getFuseListByAddressSlot().fusesByAddress[fuseAddress_];

        if (fuseInfo.fuseType == 0) {
            revert FuseNotFound(fuseAddress_);
        }

        fuseInfo.fuseState = fuseState_;
        emit FuseStateUpdated(fuseAddress_, fuseState_, fuseInfo.fuseType);
    }

    /// @notice Updates metadata for a fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param metadataId_ The ID of the metadata type to update
    /// @param metadata_ Array of metadata values
    /// @dev Reverts if:
    /// - fuseAddress_ is not found
    /// - metadataId_ is invalid
    function updateFuseMetadata(address fuseAddress_, uint256 metadataId_, bytes32[] calldata metadata_) internal {
        FuseListByAddress storage fuseInfoByAddress = _getFuseListByAddressSlot();
        MetadataTypes storage metadataTypes = _getMetadataTypesSlot();

        if (fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress == address(0)) {
            revert FuseNotFound(fuseAddress_);
        }

        if (bytes(metadataTypes.metadataTypes[uint16(metadataId_)]).length == 0) {
            revert InvalidMetadataType(metadataId_);
        }

        FuseInfo storage fuseInfo = fuseInfoByAddress.fusesByAddress[fuseAddress_];

        bool metadataIdExists = false;
        for (uint256 i; i < fuseInfo.metadataIds.length; ++i) {
            if (fuseInfo.metadataIds[i] == metadataId_) {
                metadataIdExists = true;
                break;
            }
        }
        if (!metadataIdExists) {
            fuseInfo.metadataIds.push(metadataId_);
        }

        fuseInfo.metadata[metadataId_] = metadata_;
        emit FuseMetadataUpdated(fuseAddress_, metadataId_, metadata_);
    }

    /// @notice Removes metadata from a fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param metadataId_ The ID of the metadata type to remove
    /// @dev Reverts if:
    /// - fuseAddress_ is not found
    /// - metadataId_ is not found for the fuse
    function removeFuseMetadata(address fuseAddress_, uint256 metadataId_) internal {
        FuseListByAddress storage fuseInfoByAddress = _getFuseListByAddressSlot();

        if (fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress == address(0)) {
            revert FuseNotFound(fuseAddress_);
        }

        FuseInfo storage fuseInfo = fuseInfoByAddress.fusesByAddress[fuseAddress_];

        fuseInfo.metadata[metadataId_] = new bytes32[](0);

        for (uint256 i; i < fuseInfo.metadataIds.length; ++i) {
            if (fuseInfo.metadataIds[i] == metadataId_) {
                fuseInfo.metadataIds[i] = fuseInfo.metadataIds[fuseInfo.metadataIds.length - 1];
                fuseInfo.metadataIds.pop();
                break;
            }
        }

        emit FuseMetadataUpdated(fuseAddress_, metadataId_, new bytes32[](0));
    }

    /// @notice Retrieves all fuses of a specific type
    /// @param fuseTypeId_ The ID of the fuse type to query
    /// @return fuses Array of fuse addresses
    function getFusesByType(uint16 fuseTypeId_) internal view returns (address[] memory fuses) {
        return _getFuseListsByTypeSlot().fusesByType[fuseTypeId_];
    }

    /// @notice Retrieves detailed information about a specific fuse
    /// @param fuseAddress_ The address of the fuse to query
    /// @return fuseInfo The FuseInfo struct containing all fuse details
    function getFuseByAddress(address fuseAddress_) internal view returns (FuseInfo storage fuseInfo) {
        return _getFuseListByAddressSlot().fusesByAddress[fuseAddress_];
    }

    /// @notice Adds a fuse to its market ID list
    /// @param fuseAddress_ The address of the fuse to add
    /// @dev Automatically determines market ID from the fuse contract, only adds if MARKET_ID() method exists
    function addFuseToMarketId(address fuseAddress_) internal {
        try IFuseCommon(fuseAddress_).MARKET_ID() returns (uint256 marketId) {
            FuseInfoByMarketId storage fuseInfoByMarketId = _getFuseInfoByMarketIdSlot();
            fuseInfoByMarketId.fusesByMarketId[marketId].push(fuseAddress_);

            emit FuseAddedToMarketId(fuseAddress_, marketId);
        } catch {
            // Fuse doesn't have MARKET_ID() method, skip adding to market ID list
            // This is intentionally empty - we want to silently skip fuses without MARKET_ID()
        }
    }

    /// @notice Retrieves all fuses associated with a market ID
    /// @param marketId_ The market ID to query
    /// @return fuses Array of fuse addresses
    function getFusesByMarketId(uint256 marketId_) internal view returns (address[] memory fuses) {
        return _getFuseInfoByMarketIdSlot().fusesByMarketId[marketId_];
    }

    /// @notice Retrieves fuses filtered by type, market ID, and state
    /// @param type_ The type ID to filter by
    /// @param marketId_ The market ID to filter by
    /// @param status_ The state ID to filter by
    /// @return fuses Array of fuse addresses matching all criteria
    function getFusesByTypeAndMarketIdAndStatus(
        uint16 type_,
        uint256 marketId_,
        uint16 status_
    ) internal view returns (address[] memory fuses) {
        address[] memory fusesByType = getFusesByMarketId(marketId_);
        uint256 fusesByTypeLength = fusesByType.length;

        address[] memory tempFuses = new address[](fusesByTypeLength);
        uint256 numberOfFuses;
        FuseInfo storage fuseInfo;
        for (uint256 i; i < fusesByTypeLength; ++i) {
            fuseInfo = getFuseByAddress(fusesByType[i]);
            if (fuseInfo.fuseType == type_ && fuseInfo.fuseState == status_) {
                tempFuses[numberOfFuses] = fusesByType[i];
                numberOfFuses++;
            }
        }

        if (numberOfFuses == 0) {
            return new address[](0);
        }

        address[] memory result = new address[](numberOfFuses);
        for (uint256 i; i < numberOfFuses; ++i) {
            result[i] = tempFuses[i];
        }
        return result;
    }

    /// @dev Internal function to get FusesTypes struct from storage
    /// @return fusesTypes The FusesTypes struct from storage
    function _getFusesTypesSlot() private pure returns (FusesTypes storage fusesTypes) {
        assembly {
            fusesTypes.slot := FUSES_TYPES
        }
    }

    /// @dev Internal function to get FuseInfoByMarketId struct from storage
    /// @return fuseInfoByMarketId The FuseInfoByMarketId struct from storage
    function _getFuseInfoByMarketIdSlot() private pure returns (FuseInfoByMarketId storage fuseInfoByMarketId) {
        assembly {
            fuseInfoByMarketId.slot := FUSE_INFO_BY_MARKET_ID
        }
    }

    /// @dev Internal function to get FusesStates struct from storage
    /// @return fusesStates The FusesStates struct from storage
    function _getFusesStatesSlot() private pure returns (FusesStates storage fusesStates) {
        assembly {
            fusesStates.slot := FUSES_STATES
        }
    }

    /// @dev Internal function to get FuseListsByType struct from storage
    /// @return fuseListsByType The FuseListsByType struct from storage
    function _getFuseListsByTypeSlot() private pure returns (FuseListsByType storage fuseListsByType) {
        assembly {
            fuseListsByType.slot := FUSE_LISTS_BY_TYPE
        }
    }

    /// @dev Internal function to get MetadataTypes struct from storage
    /// @return metadataTypes The MetadataTypes struct from storage
    function _getMetadataTypesSlot() private pure returns (MetadataTypes storage metadataTypes) {
        assembly {
            metadataTypes.slot := METADATA_TYPES
        }
    }

    /// @dev Internal function to get FuseInfo struct from storage
    /// @return fuseInfo The FuseInfo struct from storage
    function _getFuseListByAddressSlot() private pure returns (FuseListByAddress storage fuseInfo) {
        assembly {
            fuseInfo.slot := FUSE_INFO
        }
    }
}
