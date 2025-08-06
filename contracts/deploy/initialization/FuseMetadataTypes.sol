// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;


library FuseMetadataTypes {

    ///@dev (Unaudited, Reviewed, Tested, Audited)
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_ID = 0;
    string public constant FUSE_METADATA_AUDIT_STATUS_NAME = "Audit_Status";

    string public constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED_CODE = "Unaudited";
    string public constant FUSE_METADATA_AUDIT_STATUS_REVIEWED_CODE = "Reviewed";
    string public constant FUSE_METADATA_AUDIT_STATUS_TESTED_CODE = "Tested";
    string public constant FUSE_METADATA_AUDIT_STATUS_AUDITED_CODE = "Audited";

    uint16 public constant FUSE_METADATA_SUBSTRATE_INFO_ID = 1;
    string public constant FUSE_METADATA_SUBSTRATE_INFO_NAME = "Substrate_Info";

    ///@dev (Deposit, Balance, DEX, Perpetual, Borrow, Rewards, Collateral, Flash_Loan)
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_ID = 2;
    string public constant FUSE_METADATA_CATEGORY_INFO_NAME = "Category_Info";

    string public constant FUSE_METADATA_CATEGORY_INFO_DEPOSIT_CODE = "Deposit";
    string public constant FUSE_METADATA_CATEGORY_INFO_BALANCE_CODE = "Balance";
    string public constant FUSE_METADATA_CATEGORY_INFO_DEX_CODE = "DEX";
    string public constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL_CODE = "Perpetual";
    string public constant FUSE_METADATA_CATEGORY_INFO_BORROW_CODE = "Borrow";
    string public constant FUSE_METADATA_CATEGORY_INFO_REWARDS_CODE = "Rewards";
    string public constant FUSE_METADATA_CATEGORY_INFO_COLLATERAL_CODE = "Collateral";
    string public constant FUSE_METADATA_CATEGORY_INFO_FLASH_LOAN_CODE = "Flash_Loan";

    ///@dev (V1, V2)
    uint16 public constant FUSE_METADATA_ABI_VERSION_ID = 3;
    string public constant FUSE_METADATA_ABI_VERSION_NAME = "Abi_Version";

    string public constant FUSE_METADATA_ABI_VERSION_V1_CODE = "V1";
    string public constant FUSE_METADATA_ABI_VERSION_V2_CODE = "V2";

    ///@dev (Aave, Compound, Curve, Euler, Fluid, Gearbox, Harvest, Moonwell, Morpho, Ramses)
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_ID = 4;
    string public constant FUSE_METADATA_PROTOCOL_INFO_NAME = "Protocol_Info";

    string public constant FUSE_METADATA_PROTOCOL_INFO_AAVE_CODE = "Aave";
    string public constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND_CODE = "Compound";
    string public constant FUSE_METADATA_PROTOCOL_INFO_CURVE_CODE = "Curve";
    string public constant FUSE_METADATA_PROTOCOL_INFO_EULER_CODE = "Euler";
    string public constant FUSE_METADATA_PROTOCOL_INFO_FLUID_CODE = "Fluid";
    string public constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX_CODE = "Gearbox";
    string public constant FUSE_METADATA_PROTOCOL_INFO_HARVEST_CODE = "Harvest";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL_CODE = "Moonwell";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MORPHO_CODE = "Morpho";
    string public constant FUSE_METADATA_PROTOCOL_INFO_RAMSES_CODE = "Ramses";

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
