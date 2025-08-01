// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

///@dev (0-unaudited,  1-reviewed, 2-tested, 3-audited)
uint16 constant FUSE_METADATA_AUDIT_STATUS = 0;
string constant FUSE_METADATA_AUDIT_STATUS_NAME = "Audit_Status";

uint16 constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED = 0;
uint16 constant FUSE_METADATA_AUDIT_STATUS_REVIEWED = 1;
uint16 constant FUSE_METADATA_AUDIT_STATUS_TESTED = 2;
uint16 constant FUSE_METADATA_AUDIT_STATUS_AUDITED = 3;

string constant FUSE_METADATA_AUDIT_STATUS_UNAUDITED_NAME = "Unaudited";
string constant FUSE_METADATA_AUDIT_STATUS_REVIEWED_NAME = "Reviewed";
string constant FUSE_METADATA_AUDIT_STATUS_TESTED_NAME = "Tested";
string constant FUSE_METADATA_AUDIT_STATUS_AUDITED_NAME = "Audited";

uint16 constant FUSE_METADATA_SUBSTRATE_INFO = 1;
string constant FUSE_METADATA_SUBSTRATE_INFO_NAME = "Substrate_Info";

///@dev (0-deposit, 1-balance, 2-dex, 3-perp, 4-borrow, 5-rewards)
uint16 constant FUSE_METADATA_CATEGORY_INFO = 2;
string constant FUSE_METADATA_CATEGORY_INFO_NAME = "Category_Info";

uint16 constant FUSE_METADATA_CATEGORY_INFO_DEPOSIT = 0;
uint16 constant FUSE_METADATA_CATEGORY_INFO_BALANCE = 1;
uint16 constant FUSE_METADATA_CATEGORY_INFO_DEX = 2;
uint16 constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL = 3;
uint16 constant FUSE_METADATA_CATEGORY_INFO_BORROW = 4;
uint16 constant FUSE_METADATA_CATEGORY_INFO_REWARDS = 5;

string constant FUSE_METADATA_CATEGORY_INFO_DEPOSIT_NAME = "Deposit";
string constant FUSE_METADATA_CATEGORY_INFO_BALANCE_NAME = "Balance";
string constant FUSE_METADATA_CATEGORY_INFO_DEX_NAME = "DEX";
string constant FUSE_METADATA_CATEGORY_INFO_PERPETUAL_NAME = "Perpetual";
string constant FUSE_METADATA_CATEGORY_INFO_BORROW_NAME = "Borrow";
string constant FUSE_METADATA_CATEGORY_INFO_REWARDS_NAME = "Rewards";

///@dev (0-v1, 1-v2)
uint16 constant FUSE_METADATA_ABI_VERSION = 3;
string constant FUSE_METADATA_ABI_VERSION_NAME = "Abi_Version";

uint16 constant FUSE_METADATA_ABI_VERSION_V1 = 0;
uint16 constant FUSE_METADATA_ABI_VERSION_V2 = 1;

string constant FUSE_METADATA_ABI_VERSION_V1_NAME = "V1";
string constant FUSE_METADATA_ABI_VERSION_V2_NAME = "V2";

///@dev (0-Aave, 1-Compound, 2-Curve, 3-Euler, 4-Fluid, 5-Gearbox, 6-Harvest, 7-Moonwell, 8-Morpho, 9-Ramses)
uint16 constant FUSE_METADATA_PROTOCOL_INFO = 4;
string constant FUSE_METADATA_PROTOCOL_INFO_NAME = "Protocol_Info";

uint16 constant FUSE_METADATA_PROTOCOL_INFO_AAVE = 0;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND = 1;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_CURVE = 2;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_EULER = 3;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_FLUID = 4;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX = 5;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_HARVEST = 6;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL = 7;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_MORPHO = 8;
uint16 constant FUSE_METADATA_PROTOCOL_INFO_RAMSES = 9;

string constant FUSE_METADATA_PROTOCOL_INFO_AAVE_NAME = "Aave";
string constant FUSE_METADATA_PROTOCOL_INFO_COMPOUND_NAME = "Compound";
string constant FUSE_METADATA_PROTOCOL_INFO_CURVE_NAME = "Curve";
string constant FUSE_METADATA_PROTOCOL_INFO_EULER_NAME = "Euler";
string constant FUSE_METADATA_PROTOCOL_INFO_FLUID_NAME = "Fluid";
string constant FUSE_METADATA_PROTOCOL_INFO_GEARBOX_NAME = "Gearbox";
string constant FUSE_METADATA_PROTOCOL_INFO_HARVEST_NAME = "Harvest";
string constant FUSE_METADATA_PROTOCOL_INFO_MOONWELL_NAME = "Moonwell";
string constant FUSE_METADATA_PROTOCOL_INFO_MORPHO_NAME = "Morpho";
string constant FUSE_METADATA_PROTOCOL_INFO_RAMSES_NAME = "Ramses";

library FuseMetadataTypes {
    function getAllFuseMetadataTypeIds() public pure returns (uint16[] memory) {
        uint16[] memory fuseMetadataTypeIds = new uint16[](5);
        fuseMetadataTypeIds[0] = FUSE_METADATA_AUDIT_STATUS;
        fuseMetadataTypeIds[1] = FUSE_METADATA_SUBSTRATE_INFO;
        fuseMetadataTypeIds[2] = FUSE_METADATA_CATEGORY_INFO;
        fuseMetadataTypeIds[3] = FUSE_METADATA_ABI_VERSION;
        fuseMetadataTypeIds[4] = FUSE_METADATA_PROTOCOL_INFO;
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
