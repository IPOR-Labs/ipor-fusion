// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

struct FusesTypes {
    mapping(uint256 fuseId => string fuseType) fusesTypes;
    uint256[] fusesIds;
}

struct FusesStates {
    mapping(uint256 stateId => string fuseState) fusesStates;
    uint256[] statesIds;
}

struct FuseInfo {
    uint16 fuseState;
    uint16 fuseType;
    address fuseAddress;
    uint32 timestamp;
    mapping(uint256 metadataId => bytes32 metadata) metadata;
    uint256[] metadataIds;
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

    bytes32 private constant FUSES_TYPES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00; //todo: change to hash
    bytes32 private constant FUSES_STATES = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd01; //todo: change to hash
    bytes32 private constant FUSE_INFO = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd02; //todo: change to hash
    bytes32 private constant FUSE_METADATA = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd03; //todo: change to hash

    function addFuseType(uint256 fuseId_, string calldata fuseType_) internal {
        if (bytes(fuseType_).length == 0) {
            revert EmptyFuseType();
        }

        FusesTypes storage fusesTypes = _getFusesTypes();
        if (bytes(fusesTypes.fusesTypes[fuseId_]).length != 0) {
            revert FuseTypeAlreadyExists(fuseId_);
        }

        fusesTypes.fusesTypes[fuseId_] = fuseType_;
        fusesTypes.fusesIds.push(fuseId_);
    }

    function removeFuseType(uint256 fuseId_) internal {
        FusesTypes storage fusesTypes = _getFusesTypes();

        if (bytes(fusesTypes.fusesTypes[fuseId_]).length == 0) {
            revert FuseTypeNotFound(fuseId_);
        }

        delete fusesTypes.fusesTypes[fuseId_];

        uint256 length = fusesTypes.fusesIds.length;
        for (uint256 i; i < length; ++i) {
            if (fusesTypes.fusesIds[i] == fuseId_) {
                // Move the last element to the position being deleted
                fusesTypes.fusesIds[i] = fusesTypes.fusesIds[length - 1];
                fusesTypes.fusesIds.pop();
                break;
            }
        }
    }

    /// @dev Internal function to get FusesTypes struct from storage
    /// @return fusesTypes The FusesTypes struct from storage
    function _getFusesTypes() internal pure returns (FusesTypes storage fusesTypes) {
        assembly {
            fusesTypes.slot := FUSES_TYPES
        }
    }

    /// @dev Internal function to get FusesStates struct from storage
    /// @return fusesStates The FusesStates struct from storage
    function _getFusesStates() internal pure returns (FusesStates storage fusesStates) {
        assembly {
            fusesStates.slot := FUSES_STATES
        }
    }

    function addFuseState(uint256 stateId_, string calldata fuseState_) internal {
        if (bytes(fuseState_).length == 0) {
            revert EmptyFuseState();
        }

        FusesStates storage fusesStates = _getFusesStates();
        if (bytes(fusesStates.fusesStates[stateId_]).length != 0) {
            revert FuseStateAlreadyExists(stateId_);
        }

        fusesStates.fusesStates[stateId_] = fuseState_;
        fusesStates.statesIds.push(stateId_);
    }

    function removeFuseState(uint256 stateId_) internal {
        FusesStates storage fusesStates = _getFusesStates();

        if (bytes(fusesStates.fusesStates[stateId_]).length == 0) {
            revert FuseStateNotFound(stateId_);
        }

        delete fusesStates.fusesStates[stateId_];

        uint256 length = fusesStates.statesIds.length;
        for (uint256 i; i < length; ++i) {
            if (fusesStates.statesIds[i] == stateId_) {
                // Move the last element to the position being deleted
                fusesStates.statesIds[i] = fusesStates.statesIds[length - 1];
                fusesStates.statesIds.pop();
                break;
            }
        }
    }
}
