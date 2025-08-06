// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;


library FuseMetadataTypes {

    ///@dev (0-unaudited,  1-reviewed, 2-tested, 3-audited)
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_ID = 0;
    string public constant FUSE_METADATA_AUDIT_STATUS_NAME = "Audit_Status";

    uint16 public constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED_ID = 0;
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_REVIEWED_ID = 1;
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_TESTED_ID = 2;
    uint16 public constant FUSE_METADATA_AUDIT_STATUS_AUDITED_ID = 3;

    string public constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED_NAME = "Unaudited";
    string public constant FUSE_METADATA_AUDIT_STATUS_REVIEWED_NAME = "Reviewed";
    string public constant FUSE_METADATA_AUDIT_STATUS_TESTED_NAME = "Tested";
    string public constant FUSE_METADATA_AUDIT_STATUS_AUDITED_NAME = "Audited";

    uint16 public constant FUSE_METADATA_SUBSTRATE_INFO_ID = 1;
    string public constant FUSE_METADATA_SUBSTRATE_INFO_NAME = "Substrate_Info";

    ///@dev (0-deposit, 1-balance, 2-dex, 3-perp, 4-borrow, 5-rewards, 6-collateral, 7-flashloan)
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_ID = 2;
    string public constant FUSE_METADATA_CATEGORY_INFO_NAME = "Category_Info";

    uint16 public constant FUSE_METADATA_CATEGORY_INFO_DEPOSIT_ID = 0;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_BALANCE_ID = 1;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_DEX_ID = 2;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL_ID = 3;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_BORROW_ID = 4;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_REWARDS_ID = 5;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_COLLATERAL_ID = 6;
    uint16 public constant FUSE_METADATA_CATEGORY_INFO_FLASHLOAN_ID = 7;

    string public constant FUSE_METADATA_CATEGORY_INFO_DEPOSIT_NAME = "Deposit";
    string public constant FUSE_METADATA_CATEGORY_INFO_BALANCE_NAME = "Balance";
    string public constant FUSE_METADATA_CATEGORY_INFO_DEX_NAME = "DEX";
    string public constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL_NAME = "Perpetual";
    string public constant FUSE_METADATA_CATEGORY_INFO_BORROW_NAME = "Borrow";
    string public constant FUSE_METADATA_CATEGORY_INFO_REWARDS_NAME = "Rewards";
    string public constant FUSE_METADATA_CATEGORY_INFO_COLLATERAL_NAME = "Collateral";
    string public constant FUSE_METADATA_CATEGORY_INFO_FLASHLOAN_NAME = "FlashLoan";

    ///@dev (0-v1, 1-v2)
    uint16 public constant FUSE_METADATA_ABI_VERSION_ID = 3;
    string public constant FUSE_METADATA_ABI_VERSION_NAME = "Abi_Version";

    uint16 public constant FUSE_METADATA_ABI_VERSION_V1_ID = 0;
    uint16 public constant FUSE_METADATA_ABI_VERSION_V2_ID = 1;

    string public constant FUSE_METADATA_ABI_VERSION_V1_NAME = "V1";
    string public constant FUSE_METADATA_ABI_VERSION_V2_NAME = "V2";

    ///@dev (0-Aave, 1-Compound, 2-Curve, 3-Euler, 4-Fluid, 5-Gearbox, 6-Harvest, 7-Moonwell, 8-Morpho, 9-Ramses)
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_ID = 4;
    string public constant FUSE_METADATA_PROTOCOL_INFO_NAME = "Protocol_Info";

    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_AAVE_ID = 0;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND_ID = 1;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_CURVE_ID = 2;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_EULER_ID = 3;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_FLUID_ID = 4;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX_ID = 5;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_HARVEST_ID = 6;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL_ID = 7;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_MORPHO_ID = 8;
    uint16 public constant FUSE_METADATA_PROTOCOL_INFO_RAMSES_ID = 9;

    string public constant FUSE_METADATA_PROTOCOL_INFO_AAVE_NAME = "Aave";
    string public constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND_NAME = "Compound";
    string public constant FUSE_METADATA_PROTOCOL_INFO_CURVE_NAME = "Curve";
    string public constant FUSE_METADATA_PROTOCOL_INFO_EULER_NAME = "Euler";
    string public constant FUSE_METADATA_PROTOCOL_INFO_FLUID_NAME = "Fluid";
    string public constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX_NAME = "Gearbox";
    string public constant FUSE_METADATA_PROTOCOL_INFO_HARVEST_NAME = "Harvest";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL_NAME = "Moonwell";
    string public constant FUSE_METADATA_PROTOCOL_INFO_MORPHO_NAME = "Morpho";
    string public constant FUSE_METADATA_PROTOCOL_INFO_RAMSES_NAME = "Ramses";

    function getAllFuseMetadataTypeIds() public pure returns (uint16[] memory) {
        uint16[] memory fuseMetadataTypeIds = new uint16[](5);
        fuseMetadataTypeIds[0] = FUSE_METADATA_AUDIT_STATUS_ID;
        fuseMetadataTypeIds[1] = FUSE_METADATA_SUBSTRATE_INFO_ID;
        fuseMetadataTypeIds[2] = FUSE_METADATA_CATEGORY_INFO_ID;
        fuseMetadataTypeIds[3] = FUSE_METADATA_ABI_VERSION_ID;
        fuseMetadataTypeIds[4] = FUSE_METADATA_PROTOCOL_INFO_ID;
        return fuseMetadataTypeIds;
    }

    function getAllFuseMetadataTypeNames() public pure returns (string[] memory) {
        string[] memory fuseMetadataTypeNames = new string[](5);
        fuseMetadataTypeNames[0] = FUSE_METADATA_AUDIT_STATUS_NAME;
        fuseMetadataTypeNames[1] = FUSE_METADATA_SUBSTRATE_INFO_NAME;
        fuseMetadataTypeNames[2] = FUSE_METADATA_CATEGORY_INFO_NAME;
        fuseMetadataTypeNames[3] = FUSE_METADATA_ABI_VERSION_NAME;
        fuseMetadataTypeNames[4] = FUSE_METADATA_PROTOCOL_INFO_NAME;
        return fuseMetadataTypeNames;
    }
}
