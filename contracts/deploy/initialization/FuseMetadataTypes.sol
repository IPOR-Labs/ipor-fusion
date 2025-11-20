// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

library FuseMetadataTypes {
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_ID = 0;
    string public constant FUSE_METADATA_AUDIT_STATUS_NAME = "AUDIT_STATUS";

    string public constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED_CODE = "UNAUDITED";
    string public constant FUSE_METADATA_AUDIT_STATUS_REVIEWED_CODE = "REVIEWED";
    string public constant FUSE_METADATA_AUDIT_STATUS_TESTED_CODE = "TESTED";
    string public constant FUSE_METADATA_AUDIT_STATUS_AUDITED_CODE = "AUDITED";

    uint16 public constant FUSE_METADATA_SUBSTRATE_INFO_ID = 1;
    string public constant FUSE_METADATA_SUBSTRATE_INFO_NAME = "SUBSTRATE_INFO";

    uint16 public constant FUSE_METADATA_CATEGORY_INFO_ID = 2;
    string public constant FUSE_METADATA_CATEGORY_INFO_NAME = "CATEGORY_INFO";

    string public constant FUSE_METADATA_CATEGORY_INFO_SUPPLY_CODE = "SUPPLY";
    string public constant FUSE_METADATA_CATEGORY_INFO_BALANCE_CODE = "BALANCE";
    string public constant FUSE_METADATA_CATEGORY_INFO_DEX_CODE = "DEX";
    string public constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL_CODE = "PERPETUAL";
    string public constant FUSE_METADATA_CATEGORY_INFO_BORROW_CODE = "BORROW";
    string public constant FUSE_METADATA_CATEGORY_INFO_REWARDS_CODE = "REWARDS";
    string public constant FUSE_METADATA_CATEGORY_INFO_COLLATERAL_CODE = "COLLATERAL";
    string public constant FUSE_METADATA_CATEGORY_INFO_FLASH_LOAN_CODE = "FLASH_LOAN";
    string public constant FUSE_METADATA_CATEGORY_INFO_OTHER_CODE = "OTHER";

    uint16 public constant FUSE_METADATA_ABI_VERSION_ID = 3;
    string public constant FUSE_METADATA_ABI_VERSION_NAME = "ABI_VERSION";

    string public constant FUSE_METADATA_ABI_VERSION_V1_CODE = "V1";
    string public constant FUSE_METADATA_ABI_VERSION_V2_CODE = "V2";

    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_ID = 4;
    string public constant FUSE_METADATA_PROTOCOL_INFO_NAME = "PROTOCOL_INFO";

    string public constant FUSE_METADATA_PROTOCOL_INFO_AAVE_CODE = "AAVE";
    string public constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND_CODE = "COMPOUND";
    string public constant FUSE_METADATA_PROTOCOL_INFO_CURVE_CODE = "CURVE";
    string public constant FUSE_METADATA_PROTOCOL_INFO_EULER_CODE = "EULER";
    string public constant FUSE_METADATA_PROTOCOL_INFO_FLUID_CODE = "FLUID";
    string public constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX_CODE = "GEARBOX";
    string public constant FUSE_METADATA_PROTOCOL_INFO_HARVEST_CODE = "HARVEST";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL_CODE = "MOONWELL";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MORPHO_CODE = "MORPHO";
    string public constant FUSE_METADATA_PROTOCOL_INFO_RAMSES_CODE = "RAMSES";
    string public constant FUSE_METADATA_PROTOCOL_INFO_ERC4626_CODE = "ERC4626";
    string public constant FUSE_METADATA_PROTOCOL_INFO_ERC20_CODE = "ERC20";
    string public constant FUSE_METADATA_PROTOCOL_INFO_FUSION_CODE = "FUSION";
    string public constant FUSE_METADATA_PROTOCOL_INFO_META_MORPHO_CODE = "META_MORPHO";
    string public constant FUSE_METADATA_PROTOCOL_INFO_UNISWAP_CODE = "UNISWAP";
    string public constant FUSE_METADATA_PROTOCOL_INFO_PENDLE_CODE = "PENDLE";

    function getAllFuseMetadataTypeIds() internal pure returns (uint16[] memory) {
        uint16[] memory fuseMetadataTypeIds = new uint16[](5);
        fuseMetadataTypeIds[0] = FUSE_METADATA_AUDIT_STATUS_ID;
        fuseMetadataTypeIds[1] = FUSE_METADATA_SUBSTRATE_INFO_ID;
        fuseMetadataTypeIds[2] = FUSE_METADATA_CATEGORY_INFO_ID;
        fuseMetadataTypeIds[3] = FUSE_METADATA_ABI_VERSION_ID;
        fuseMetadataTypeIds[4] = FUSE_METADATA_PROTOCOL_INFO_ID;
        return fuseMetadataTypeIds;
    }

    function getAllFuseMetadataTypeNames() internal pure returns (string[] memory) {
        string[] memory fuseMetadataTypeNames = new string[](5);
        fuseMetadataTypeNames[0] = FUSE_METADATA_AUDIT_STATUS_NAME;
        fuseMetadataTypeNames[1] = FUSE_METADATA_SUBSTRATE_INFO_NAME;
        fuseMetadataTypeNames[2] = FUSE_METADATA_CATEGORY_INFO_NAME;
        fuseMetadataTypeNames[3] = FUSE_METADATA_ABI_VERSION_NAME;
        fuseMetadataTypeNames[4] = FUSE_METADATA_PROTOCOL_INFO_NAME;
        return fuseMetadataTypeNames;
    }

    function stringToBytes32Array(string memory source) public pure returns (bytes32[] memory) {
        bytes memory sourceBytes = bytes(source);
        uint256 sourceLength = sourceBytes.length;
        uint256 arrayLength = (sourceLength + 31) / 32;
        bytes32[] memory result = new bytes32[](arrayLength);

        for (uint256 i = 0; i < arrayLength; i++) {
            bytes32 chunk;
            for (uint256 j = 0; j < 32; j++) {
                uint256 index = i * 32 + j;
                if (index < sourceLength) {
                    chunk |= bytes32(uint256(uint8(sourceBytes[index])) << (248 - j * 8));
                }
            }
            result[i] = chunk;
        }

        return result;
    }
}
