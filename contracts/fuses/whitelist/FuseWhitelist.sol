// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {FuseWhitelistAccessControl} from "./FuseWhitelistAccessControl.sol";
import {FuseWhitelistLib, FuseInfo} from "./FuseWhitelistLib.sol";
import {UniversalReader} from "../../universal_reader/UniversalReader.sol";

/// @title FuseWhitelist
/// @notice Manages the whitelisting and configuration of fuses in the system
/// @dev Implements UUPS upgradeable pattern and access control
contract FuseWhitelist is UUPSUpgradeable, FuseWhitelistAccessControl, UniversalReader {
    error FuseWhitelistInvalidInputLength();
    error FuseWhitelistInvalidInput();
    error FuseWhitelistFuseAlreadyExists(address fuseAddress);

    /// @notice Initializes the contract
    /// @param initialAdmin_ The address that will own the contract
    /// @dev Should be a multi-sig wallet for security
    function initialize(address initialAdmin_) external initializer {
        __IporFusionAccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);
    }

    /// @notice Adds new fuse types to the system
    /// @param fuseTypeIds_ Array of unique identifiers for fuse types
    /// @param fuseTypeNames_ Array of descriptive names for fuse types
    /// @return bool True if operation was successful
    /// @dev Requires FUSE_TYPE_MANAGER_ROLE
    /// @dev Arrays must have equal length
    function addFuseTypes(
        uint16[] calldata fuseTypeIds_,
        string[] calldata fuseTypeNames_
    ) external onlyRole(FUSE_TYPE_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseTypeIds_.length;
        if (length != fuseTypeNames_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.addFuseType(fuseTypeIds_[i], fuseTypeNames_[i]);
        }
        return true;
    }

    /// @notice Adds new fuse states to the system
    /// @param fuseStateIds_ Array of unique identifiers for fuse states
    /// @param fuseStateNames_ Array of descriptive names for fuse states
    /// @return bool True if operation was successful
    /// @dev Requires FUSE_STATE_MANAGER_ROLE
    /// @dev Arrays must have equal length
    function addFuseStates(
        uint16[] calldata fuseStateIds_,
        string[] calldata fuseStateNames_
    ) external onlyRole(FUSE_STATE_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseStateIds_.length;
        if (length != fuseStateNames_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.addFuseState(fuseStateIds_[i], fuseStateNames_[i]);
        }
        return true;
    }

    /// @notice Adds new metadata types to the system
    /// @param metadataIds_ Array of unique identifiers for metadata types
    /// @param metadataTypes_ Array of descriptive names for metadata types
    /// @return bool True if operation was successful
    /// @dev Requires FUSE_METADATA_MANAGER_ROLE
    /// @dev Arrays must have equal length
    function addMetadataTypes(
        uint16[] calldata metadataIds_,
        string[] calldata metadataTypes_
    ) external onlyRole(FUSE_METADATA_MANAGER_ROLE) returns (bool) {
        uint256 length = metadataIds_.length;
        if (length != metadataTypes_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.addMetadataType(metadataIds_[i], metadataTypes_[i]);
        }
        return true;
    }

    /// @notice Adds new fuses to the system with their types and states
    /// @param fuses_ Array of fuse contract addresses
    /// @param types_ Array of fuse type IDs corresponding to each fuse
    /// @param states_ Array of fuse state IDs corresponding to each fuse
    /// @param deploymentTimestamps_ Array of deployment timestamps corresponding to each fuse
    /// @return bool True if operation was successful
    /// @dev Requires ADD_FUSE_MANAGER_ROLE
    /// @dev All arrays must have equal length
    /// @dev Automatically adds fuses to market ID lists based on their MARKET_ID
    function addFuses(
        address[] calldata fuses_,
        uint16[] calldata types_,
        uint16[] calldata states_,
        uint32[] calldata deploymentTimestamps_
    ) external onlyRole(ADD_FUSE_MANAGER_ROLE) returns (bool) {
        uint256 length = fuses_.length;
        if (length != types_.length || length != states_.length || length != deploymentTimestamps_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            if (FuseWhitelistLib.isFuseAddressExists(fuses_[i])) {
                revert FuseWhitelistFuseAlreadyExists(fuses_[i]);
            }
            FuseWhitelistLib.addFuseToListByType(types_[i], fuses_[i]);
            FuseWhitelistLib.addFuseInfo(types_[i], fuses_[i], deploymentTimestamps_[i]);
            FuseWhitelistLib.addFuseToMarketId(fuses_[i]);
            FuseWhitelistLib.updateFuseState(fuses_[i], states_[i]);
        }
        return true;
    }

    /// @notice Updates the type of existing fuses
    /// @param fuseAddresses_ Array of fuse addresses to update
    /// @param fuseTypes_ Array of new fuse type IDs for each fuse
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_TYPE_MANAGER_ROLE
    /// @dev All arrays must have equal length
    /// @dev Each fuse must exist in the system
    /// @dev Each new fuse type must be valid
    function updateFuseType(
        address[] calldata fuseAddresses_,
        uint16[] calldata fuseTypes_
    ) external onlyRole(UPDATE_FUSE_TYPE_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseAddresses_.length;
        if (length != fuseTypes_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.updateFuseType(fuseAddresses_[i], fuseTypes_[i]);
        }
        return true;
    }

    /// @notice Updates the state of an existing fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param fuseState_ The new state ID to set
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_STATE_MANAGER_ROLE
    /// @dev Fuse must exist in the system
    /// @dev New state must be valid
    function updateFuseState(
        address fuseAddress_,
        uint16 fuseState_
    ) external onlyRole(UPDATE_FUSE_STATE_MANAGER_ROLE) returns (bool) {
        FuseWhitelistLib.updateFuseState(fuseAddress_, fuseState_);
        return true;
    }

    /// @notice Updates metadata for an existing fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param metadataId_ The ID of the metadata type to update
    /// @param metadata_ Array of metadata values to set
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_METADATA_MANAGER_ROLE
    /// @dev Fuse must exist in the system
    /// @dev Metadata type must be valid
    function updateFuseMetadata(
        address fuseAddress_,
        uint16 metadataId_,
        bytes32[] calldata metadata_
    ) external onlyRole(UPDATE_FUSE_METADATA_MANAGER_ROLE) returns (bool) {
        FuseWhitelistLib.updateFuseMetadata(fuseAddress_, metadataId_, metadata_);
        return true;
    }

    /// @notice Updates metadata for multiple existing fuses
    /// @param fuseAddresses_ Array of fuse addresses to update
    /// @param metadataIds_ Array of metadata type IDs to update for each fuse
    /// @param metadatas_ Array of metadata value arrays for each fuse
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_METADATA_MANAGER_ROLE
    /// @dev All arrays must have equal length
    /// @dev Each fuse must exist in the system
    /// @dev Each metadata type must be valid
    function updateFusesMetadata(
        address[] calldata fuseAddresses_,
        uint16[] calldata metadataIds_,
        bytes32[][] calldata metadatas_
    ) external onlyRole(UPDATE_FUSE_METADATA_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseAddresses_.length;
        if (length != metadataIds_.length || length != metadatas_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.updateFuseMetadata(fuseAddresses_[i], metadataIds_[i], metadatas_[i]);
        }
        return true;
    }

    /// @notice Updates the deployment timestamp of an existing fuse
    /// @param fuseAddress_ The address of the fuse to update
    /// @param deploymentTimestamp_ The new deployment timestamp to set
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE
    /// @dev Fuse must exist in the system
    /// @dev Deployment timestamp must be non-zero
    function updateFuseDeploymentTimestamp(
        address fuseAddress_,
        uint32 deploymentTimestamp_
    ) external onlyRole(UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE) returns (bool) {
        FuseWhitelistLib.updateFuseDeploymentTimestamp(fuseAddress_, deploymentTimestamp_);
        return true;
    }

    /// @notice Updates the deployment timestamps for multiple existing fuses
    /// @param fuseAddresses_ Array of fuse addresses to update
    /// @param deploymentTimestamps_ Array of new deployment timestamps for each fuse
    /// @return bool True if operation was successful
    /// @dev Requires UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE
    /// @dev All arrays must have equal length
    /// @dev Each fuse must exist in the system
    /// @dev Each deployment timestamp must be non-zero
    function updateFusesDeploymentTimestamps(
        address[] calldata fuseAddresses_,
        uint32[] calldata deploymentTimestamps_
    ) external onlyRole(UPDATE_FUSE_DEPLOYMENT_TIMESTAMP_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseAddresses_.length;
        if (length != deploymentTimestamps_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; ++i) {
            FuseWhitelistLib.updateFuseDeploymentTimestamp(fuseAddresses_[i], deploymentTimestamps_[i]);
        }
        return true;
    }

    /// @notice Retrieves all registered fuse types
    /// @return Array of fuse type IDs
    /// @return Array of fuse type names
    function getFuseTypes() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getFuseTypes();
    }

    /// @notice Retrieves the description of a specific fuse type
    /// @param fuseTypeId_ The ID of the fuse type to query
    /// @return The description string of the fuse type
    function getFuseTypeDescription(uint16 fuseTypeId_) external view returns (string memory) {
        return FuseWhitelistLib.getFuseTypeDescription(fuseTypeId_);
    }

    /// @notice Retrieves all registered fuse states
    /// @return Array of fuse state IDs
    /// @return Array of fuse state names
    function getFuseStates() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getFuseStates();
    }

    /// @notice Retrieves the description of a specific fuse state
    /// @param fuseStateId_ The ID of the fuse state to query
    /// @return The description string of the fuse state
    function getFuseStateName(uint16 fuseStateId_) external view returns (string memory) {
        return FuseWhitelistLib.getFuseStateName(fuseStateId_);
    }

    /// @notice Retrieves all registered metadata types
    /// @return Array of metadata type IDs
    /// @return Array of metadata type names
    function getMetadataTypes() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getMetadataTypes();
    }

    /// @notice Retrieves the description of a specific metadata type
    /// @param metadataId_ The ID of the metadata type to query
    /// @return The description string of the metadata type
    function getMetadataType(uint16 metadataId_) external view returns (string memory) {
        return FuseWhitelistLib.getMetadataType(metadataId_);
    }

    /// @notice Retrieves all fuses of a specific type
    /// @param fuseTypeId_ The ID of the fuse type to query
    /// @return Array of fuse addresses
    function getFusesByType(uint16 fuseTypeId_) external view returns (address[] memory) {
        return FuseWhitelistLib.getFusesByType(fuseTypeId_);
    }

    /// @notice Retrieves detailed information about a specific fuse
    /// @param fuseAddress_ The address of the fuse to query
    /// @return fuseState The current state of the fuse
    /// @return fuseType The type of the fuse
    /// @return fuseAddress The address of the fuse
    /// @return timestamp The timestamp when the fuse was added
    function getFuseByAddress(
        address fuseAddress_
    ) external view returns (uint16 fuseState, uint16 fuseType, address fuseAddress, uint32 timestamp) {
        FuseInfo storage fuseInfo = FuseWhitelistLib.getFuseByAddress(fuseAddress_);
        fuseState = fuseInfo.fuseState;
        fuseType = fuseInfo.fuseType;
        fuseAddress = fuseInfo.fuseAddress;
        timestamp = fuseInfo.timestamp;
    }

    /// @notice Retrieves all metadata information for a specific fuse
    /// @param fuseAddress_ The address of the fuse to query
    /// @return metadataIds Array of metadata type IDs associated with the fuse
    /// @return metadata Array of metadata value arrays corresponding to each metadata ID
    /// @dev Reverts if fuseAddress_ is zero address
    /// @dev Returns empty arrays if fuse has no metadata
    function getFuseMetadataInfo(
        address fuseAddress_
    ) external view returns (uint256[] memory metadataIds, bytes32[][] memory metadata) {
        if (fuseAddress_ == address(0)) {
            revert FuseWhitelistInvalidInput();
        }

        FuseInfo storage fuseInfo = FuseWhitelistLib.getFuseByAddress(fuseAddress_);

        uint256 length = fuseInfo.metadataIds.length;

        if (length == 0) {
            return (new uint256[](0), new bytes32[][](0));
        }

        metadataIds = new uint256[](length);
        metadata = new bytes32[][](length);

        for (uint256 i; i < length; ++i) {
            metadataIds[i] = fuseInfo.metadataIds[i];
            metadata[i] = fuseInfo.metadata[metadataIds[i]];
        }
    }

    /// @notice Retrieves all fuses associated with a specific market ID
    /// @param marketId_ The ID of the market to query
    /// @return Array of fuse addresses
    function getFusesByMarketId(uint256 marketId_) external view returns (address[] memory) {
        return FuseWhitelistLib.getFusesByMarketId(marketId_);
    }

    /// @notice Retrieves fuses filtered by type, market ID, and state
    /// @param type_ The type ID to filter by
    /// @param marketId_ The market ID to filter by
    /// @param status_ The state ID to filter by
    /// @return Array of fuse addresses matching all criteria
    function getFusesByTypeAndMarketIdAndStatus(
        uint16 type_,
        uint256 marketId_,
        uint16 status_
    ) external view returns (address[] memory) {
        return FuseWhitelistLib.getFusesByTypeAndMarketIdAndStatus(type_, marketId_, status_);
    }

    /// @notice Authorizes an upgrade to a new implementation
    /// @param newImplementation_ Address of the new implementation
    /// @dev Required by the OZ UUPS module
    /// @dev Only callable by DEFAULT_ADMIN_ROLE
    //solhint-disable-next-line
    function _authorizeUpgrade(address newImplementation_) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
