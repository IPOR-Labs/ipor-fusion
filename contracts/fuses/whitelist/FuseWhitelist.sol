// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {FuseWhitelistLib, FuseInfo} from "./FuseWhitelistLib.sol";
import {FuseWhitelistAccessControl} from "./FuseWhitelistAccessControl.sol";

contract FuseWhitelist is UUPSUpgradeable, FuseWhitelistAccessControl {
    error FuseWhitelistInvalidInputLength();

    /// @notice Initializes the contract
    /// @param initialAdmin_ The address that will own the contract
    /// @dev Should be a multi-sig wallet for security
    function initialize(address initialAdmin_) external initializer {
        __IporFusionAccessControl_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin_);
    }

    function addFuseTypes(
        uint16[] calldata fuseTypeIds_,
        string[] calldata fuseTypeNames_
    ) external onlyRole(CONFIGURATION_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseTypeIds_.length;
        if (length != fuseTypeNames_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; i++) {
            FuseWhitelistLib.addFuseType(fuseTypeIds_[i], fuseTypeNames_[i]);
        }
        return true;
    }

    function getFuseTypes() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getFuseTypes();
    }

    function getFuseTypeDescription(uint16 fuseTypeId_) external view returns (string memory) {
        return FuseWhitelistLib.getFuseTypeDescription(fuseTypeId_);
    }

    function addFuseStates(
        uint16[] calldata fuseStateIds_,
        string[] calldata fuseStateNames_
    ) external onlyRole(CONFIGURATION_MANAGER_ROLE) returns (bool) {
        uint256 length = fuseStateIds_.length;
        if (length != fuseStateNames_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; i++) {
            FuseWhitelistLib.addFuseState(fuseStateIds_[i], fuseStateNames_[i]);
        }
        return true;
    }

    function getFuseStates() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getFuseStates();
    }

    function getFuseStateDescription(uint16 fuseStateId_) external view returns (string memory) {
        return FuseWhitelistLib.getFuseStateDescription(fuseStateId_);
    }

    function addMetadataTypes(
        uint16[] calldata metadataIds_,
        string[] calldata metadataTypes_
    ) external onlyRole(CONFIGURATION_MANAGER_ROLE) returns (bool) {
        uint256 length = metadataIds_.length;
        if (length != metadataTypes_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; i++) {
            FuseWhitelistLib.addMetadataType(metadataIds_[i], metadataTypes_[i]);
        }
        return true;
    }

    function getMetadataTypes() external view returns (uint16[] memory, string[] memory) {
        return FuseWhitelistLib.getMetadataTypes();
    }

    function getMetadataTypeDescription(uint16 metadataId_) external view returns (string memory) {
        return FuseWhitelistLib.getMetadataTypeDescription(metadataId_);
    }

    function addFuses(
        address[] calldata fuses_,
        uint16[] calldata types_
    ) external onlyRole(ADD_FUSE_MENAGER_ROLE) returns (bool) {
        uint256 length = fuses_.length;
        if (length != types_.length) {
            revert FuseWhitelistInvalidInputLength();
        }
        for (uint256 i; i < length; i++) {
            FuseWhitelistLib.addFuseToListByType(types_[i], fuses_[i]);
            FuseWhitelistLib.addFuseInfo(types_[i], fuses_[i]);
        }
        return true;
    }

    function getFuseByType(uint16 fuseTypeId_) external view returns (address[] memory) {
        return FuseWhitelistLib.getFuseByType(fuseTypeId_);
    }

    function getFuseByAddress(
        address fuseAddress_
    ) external view returns (uint16 fuseState, uint16 fuseType, address fuseAddress, uint32 timestamp) {
        FuseInfo storage fuseInfo = FuseWhitelistLib.getFuseByAddress(fuseAddress_);
        fuseState = fuseInfo.fuseState;
        fuseType = fuseInfo.fuseType;
        fuseAddress = fuseInfo.fuseAddress;
        timestamp = fuseInfo.timestamp;
    }

    function updateFuseState(
        address fuseAddress_,
        uint16 fuseState_
    ) external onlyRole(UPDATE_FUSE_STATE_ROLE) returns (bool) {
        FuseWhitelistLib.updateFuseState(fuseAddress_, fuseState_);
        return true;
    }

    function updateFuseMetadata(
        address fuseAddress_,
        uint16 metadataId_,
        bytes32[] calldata metadata_
    ) external onlyRole(UPDATE_FUSE_METADATA_ROLE) returns (bool) {
        FuseWhitelistLib.updateFuseMetadata(fuseAddress_, metadataId_, metadata_);
        return true;
    }
    /// @dev Required by the OZ UUPS module
    /// @param newImplementation Address of the new implementation
    //solhint-disable-next-line
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
