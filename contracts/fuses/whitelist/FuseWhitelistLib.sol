// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";

struct FusesTypes {
    mapping(uint16 fuseId => string fuseType) fusesTypes;
    uint16[] fusesIds;
}

struct FusesStates {
    mapping(uint16 stateId => string fuseState) fusesStates;
    uint16[] statesIds;
}

struct MetadataTypes {
    mapping(uint16 metadataId => string metadataType) metadataTypes;
    uint16[] metadataIds;
}

struct FuseListsByType {
    mapping(uint16 fuseTypeId => address[] fuses) fusesByType;
}

struct FuseInfo {
    uint16 fuseState;
    uint16 fuseType;
    address fuseAddress;
    uint32 timestamp;
    mapping(uint256 metadataId => bytes32[] metadata) metadata;
    uint256[] metadataIds;
}

struct FuseListByAddress {
    mapping(address fuseAddress => FuseInfo fuseInfo) fusesByAddress;
}

struct FuseInfoByMarketId {
    mapping(uint256 marketId => address[] fuses) fusesByMarketId;
}

library FuseWhitelistLib {
    /// @notice Thrown when attempting to add an empty fuse type
    error EmptyFuseType();
    /// @notice Thrown when attempting to add a fuse type that already exists
    error FuseTypeAlreadyExists(uint256 fuseId);
    /// @notice Thrown when attempting to remove a non-existent fuse type
    error FuseTypeNotFound(uint256 fuseId);
    /// @notice Thrown when attempting to add an empty fuse state
    error EmptyFuseState();
    /// @notice Thrown when attempting to add a fuse state that already exists
    error FuseStateAlreadyExists(uint256 stateId);
    /// @notice Thrown when attempting to remove a non-existent fuse state
    error FuseStateNotFound(uint256 stateId);
    /// @notice Thrown when attempting to add an empty metadata type
    error EmptyMetadataType();
    /// @notice Thrown when attempting to add a metadata type that already exists
    error MetadataTypeAlreadyExists(uint256 metadataId);
    /// @notice Thrown when attempting to remove a non-existent metadata type
    error MetadataTypeNotFound(uint256 metadataId);
    /// @notice Thrown when attempting to add a fuse to a list with an invalid type ID
    error InvalidFuseTypeId(uint256 fuseTypeId);
    /// @notice Thrown when attempting to add a zero address fuse
    error ZeroAddressFuse();
    /// @notice Thrown when attempting to remove a non-existent fuse from a type list
    error FuseNotFoundInType(uint256 fuseTypeId, address fuse);
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
    /// @notice Thrown when attempting to remove metadata from a non-existent fuse
    error FuseMetadataNotFound(address fuseAddress, uint256 metadataId);

    event FuseTypeAdded(uint16 fuseId, string fuseType);
    event FuseStateAdded(uint16 stateId, string fuseState);
    event MetadataTypeAdded(uint16 metadataId, string metadataType);
    event FuseAddedToListByType(uint16 fuseTypeId, address fuseAddress);
    event FuseInfoUpdated(address fuseAddress, uint16 fuseState, uint16 fuseType);
    event FuseMetadataUpdated(address fuseAddress, uint256 metadataId, bytes32[] metadata);
    event FuseStateUpdated(address fuseAddress, uint16 fuseState, uint16 fuseType);
    event FuseAddedToMarketId(address fuseAddress, uint256 marketId);

    bytes32 private constant FUSES_TYPES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00; //todo: change to hash
    bytes32 private constant FUSES_STATES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd01; //todo: change to hash
    bytes32 private constant FUSE_INFO = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd02; //todo: change to hash
    bytes32 private constant FUSE_LISTS_BY_TYPE = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd04; //todo: change to hash
    bytes32 private constant FUSE_INFO_BY_MARKET_ID =
        0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd03; //todo: change to hash
    bytes32 private constant METADATA_TYPES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd05; //todo: change to hash

    function addFuseType(uint16 fuseId_, string calldata fuseType_) internal {
        if (bytes(fuseType_).length == 0) {
            revert EmptyFuseType();
        }

        FusesTypes storage fusesTypes = _getFusesTypes();
        if (bytes(fusesTypes.fusesTypes[fuseId_]).length != 0) {
            revert FuseTypeAlreadyExists(fuseId_);
        }

        fusesTypes.fusesTypes[fuseId_] = fuseType_;
        fusesTypes.fusesIds.push(fuseId_);

        emit FuseTypeAdded(fuseId_, fuseType_);
    }

    function getFuseTypes() internal view returns (uint16[] memory fuseTypesIds, string[] memory fuseTypesNames) {
        FusesTypes storage fusesTypes = _getFusesTypes();
        fuseTypesIds = fusesTypes.fusesIds;

        uint256 length = fusesTypes.fusesIds.length;
        fuseTypesNames = new string[](length);
        for (uint256 i; i < length; ++i) {
            fuseTypesNames[i] = fusesTypes.fusesTypes[fuseTypesIds[i]];
        }
        return (fuseTypesIds, fuseTypesNames);
    }

    function getFuseTypeDescription(uint16 fuseTypeId_) internal view returns (string memory) {
        return _getFusesTypes().fusesTypes[fuseTypeId_];
    }

    function addFuseState(uint16 stateId_, string calldata fuseState_) internal {
        if (bytes(fuseState_).length == 0) {
            revert EmptyFuseState();
        }

        FusesStates storage fusesStates = _getFusesStates();
        if (bytes(fusesStates.fusesStates[stateId_]).length != 0) {
            revert FuseStateAlreadyExists(stateId_);
        }

        fusesStates.fusesStates[stateId_] = fuseState_;
        fusesStates.statesIds.push(stateId_);

        emit FuseStateAdded(stateId_, fuseState_);
    }

    function getFuseStates() internal view returns (uint16[] memory fuseStatesIds, string[] memory fuseStatesNames) {
        FusesStates storage fusesStates = _getFusesStates();
        fuseStatesIds = fusesStates.statesIds;

        uint256 length = fusesStates.statesIds.length;
        fuseStatesNames = new string[](length);
        for (uint256 i; i < length; ++i) {
            fuseStatesNames[i] = fusesStates.fusesStates[fuseStatesIds[i]];
        }
        return (fuseStatesIds, fuseStatesNames);
    }

    function getFuseStateDescription(uint16 fuseStateId_) internal view returns (string memory) {
        return _getFusesStates().fusesStates[fuseStateId_];
    }

    function addMetadataType(uint16 metadataId_, string calldata metadataType_) internal {
        if (bytes(metadataType_).length == 0) {
            revert EmptyMetadataType();
        }

        MetadataTypes storage metadataTypes = _getMetadataTypes();
        if (bytes(metadataTypes.metadataTypes[metadataId_]).length != 0) {
            revert MetadataTypeAlreadyExists(metadataId_);
        }

        metadataTypes.metadataTypes[metadataId_] = metadataType_;
        metadataTypes.metadataIds.push(metadataId_);

        emit MetadataTypeAdded(metadataId_, metadataType_);
    }

    function getMetadataTypes()
        internal
        view
        returns (uint16[] memory metadataIds, string[] memory metadataTypesDescriptions)
    {
        MetadataTypes storage metadataTypes = _getMetadataTypes();
        metadataIds = metadataTypes.metadataIds;

        uint256 length = metadataTypes.metadataIds.length;
        metadataTypesDescriptions = new string[](length);
        for (uint256 i; i < length; ++i) {
            metadataTypesDescriptions[i] = metadataTypes.metadataTypes[metadataIds[i]];
        }
        return (metadataIds, metadataTypesDescriptions);
    }

    function getMetadataTypeDescription(uint16 metadataId_) internal view returns (string memory) {
        return _getMetadataTypes().metadataTypes[metadataId_];
    }

    function addFuseToListByType(uint16 fuseTypeId_, address fuse_) internal {
        if (fuse_ == address(0)) {
            revert ZeroAddressFuse();
        }

        FuseListsByType storage fuseListsByType = _getFuseListsByType();
        FusesTypes storage fusesTypes = _getFusesTypes();

        // Verify that the fuse type exists
        if (bytes(fusesTypes.fusesTypes[fuseTypeId_]).length == 0) {
            revert InvalidFuseTypeId(fuseTypeId_);
        }

        // Add the fuse to the list for this type
        fuseListsByType.fusesByType[fuseTypeId_].push(fuse_);
    }

    function addFuseInfo(uint16 fuseType_, address fuseAddress_) internal {
        if (fuseAddress_ == address(0)) {
            revert ZeroAddressFuseInfo();
        }

        FuseListByAddress storage fuseInfoByAddress = _getFuseInfo();
        FusesTypes storage fusesTypes = _getFusesTypes();

        // Verify that the fuse type exists
        if (bytes(fusesTypes.fusesTypes[fuseType_]).length == 0) {
            revert InvalidFuseTypeForInfo(fuseType_);
        }

        // Set default values for new fuse info
        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseType = fuseType_;
        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress = fuseAddress_;
        fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseState = 0; // Default state
        fuseInfoByAddress.fusesByAddress[fuseAddress_].timestamp = uint32(block.timestamp);
        // metadataIds array will be empty by default
    }

    function updateFuseState(address fuseAddress_, uint16 fuseState_) internal {
        FusesStates storage fusesStates = _getFusesStates();

        if (fuseState_ == 0 || bytes(fusesStates.fusesStates[fuseState_]).length == 0) {
            revert InvalidFuseState(fuseState_);
        }

        FuseInfo storage fuseInfo = _getFuseInfo().fusesByAddress[fuseAddress_];

        if (fuseInfo.fuseType == 0) {
            revert FuseNotFound(fuseAddress_);
        }

        fuseInfo.fuseState = fuseState_;
        emit FuseStateUpdated(fuseAddress_, fuseState_, fuseInfo.fuseType);
    }

    function updateFuseMetadata(address fuseAddress_, uint256 metadataId_, bytes32[] calldata metadata_) internal {
        FuseListByAddress storage fuseInfoByAddress = _getFuseInfo();
        MetadataTypes storage metadataTypes = _getMetadataTypes();

        // Verify that the fuse exists
        if (fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress == address(0)) {
            revert FuseNotFound(fuseAddress_);
        }

        // Verify that the metadata type exists
        if (bytes(metadataTypes.metadataTypes[uint16(metadataId_)]).length == 0) {
            revert InvalidMetadataType(metadataId_);
        }

        // Add metadata to the fuse
        FuseInfo storage fuseInfo = fuseInfoByAddress.fusesByAddress[fuseAddress_];

        // Add metadataId to the array if it doesn't exist
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

        // Add the metadata value
        fuseInfo.metadata[metadataId_] = metadata_;
        emit FuseMetadataUpdated(fuseAddress_, metadataId_, metadata_);
    }

    function removeFuseMetadata(address fuseAddress_, uint256 metadataId_) internal {
        FuseListByAddress storage fuseInfoByAddress = _getFuseInfo();

        // Verify that the fuse exists
        if (fuseInfoByAddress.fusesByAddress[fuseAddress_].fuseAddress == address(0)) {
            revert FuseNotFound(fuseAddress_);
        }

        FuseInfo storage fuseInfo = fuseInfoByAddress.fusesByAddress[fuseAddress_];

        fuseInfo.metadata[metadataId_] = new bytes32[](0);

        // Remove the metadataId from the array if it exists
        for (uint256 i; i < fuseInfo.metadataIds.length; ++i) {
            if (fuseInfo.metadataIds[i] == metadataId_) {
                fuseInfo.metadataIds[i] = fuseInfo.metadataIds[fuseInfo.metadataIds.length - 1];
                fuseInfo.metadataIds.pop();
                break;
            }
        }

        emit FuseMetadataUpdated(fuseAddress_, metadataId_, new bytes32[](0));
    }

    function getFuseByType(uint16 fuseTypeId_) internal view returns (address[] memory fuses) {
        return _getFuseListsByType().fusesByType[fuseTypeId_];
    }

    function getFuseByAddress(address fuseAddress_) internal view returns (FuseInfo storage fuseInfo) {
        return _getFuseInfo().fusesByAddress[fuseAddress_];
    }

    function addFuseToMarketId(address fuseAddress_) internal {
        uint256 marketId = IFuseCommon(fuseAddress_).MARKET_ID();
        FuseInfoByMarketId storage fuseInfoByMarketId = _getFuseInfoByMarketId();
        fuseInfoByMarketId.fusesByMarketId[marketId].push(fuseAddress_);

        emit FuseAddedToMarketId(fuseAddress_, marketId);
    }

    /// @dev Internal function to get FusesTypes struct from storage
    /// @return fusesTypes The FusesTypes struct from storage
    function _getFusesTypes() internal pure returns (FusesTypes storage fusesTypes) {
        assembly {
            fusesTypes.slot := FUSES_TYPES
        }
    }

    function _getFuseInfoByMarketId() private pure returns (FuseInfoByMarketId storage fuseInfoByMarketId) {
        assembly {
            fuseInfoByMarketId.slot := FUSE_INFO_BY_MARKET_ID
        }
    }

    /// @dev Internal function to get FusesStates struct from storage
    /// @return fusesStates The FusesStates struct from storage
    function _getFusesStates() private pure returns (FusesStates storage fusesStates) {
        assembly {
            fusesStates.slot := FUSES_STATES
        }
    }

    function _getFuseListsByType() private pure returns (FuseListsByType storage fuseListsByType) {
        assembly {
            fuseListsByType.slot := FUSE_LISTS_BY_TYPE
        }
    }

    function _getMetadataTypes() private pure returns (MetadataTypes storage metadataTypes) {
        assembly {
            metadataTypes.slot := METADATA_TYPES
        }
    }

    function _getFuseInfo() private pure returns (FuseListByAddress storage fuseInfo) {
        assembly {
            fuseInfo.slot := FUSE_INFO
        }
    }
}
