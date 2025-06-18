// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

///@dev (0-unaudited,  1-reviewed, 2-tested, 3-audited)
uint16 constant FUSE_METADATA_AUDIT_STATUS = 0;
string constant FUSE_METADATA_AUDIT_STATUS_NAME = "Audit_Status";

uint16 constant FUSE_METADATA_SUBSTRATE_INFO = 1;
string constant FUSE_METADATA_SUBSTRATE_INFO_NAME = "Substrate_Info";

///@dev (0-deposit, 1-balance, 2-dex, 3-perp, 4-borrow, 5-rewards)
uint16 constant FUSE_METADATA_CATEGORY_INFO = 2;
string constant FUSE_METADATA_CATEGORY_INFO_NAME = "Category_Info";

///@dev (0-v1, 1-v2)
uint16 constant FUSE_METADATA_ABI_VERSION = 3;
string constant FUSE_METADATA_ABI_VERSION_NAME = "Abi_Version";

///@dev (0-Aave, 1-Compound, 2-Curve, 3-Euler, 4-Fluid, 5-Gearbox, 6-Harvest, 7-Moonwell, 8-Morpho, 9-Ramses)
uint16 constant FUSE_METADATA_PROTOCOL_INFO = 4;
string constant FUSE_METADATA_PROTOCOL_INFO_NAME = "Protocol_Info";

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
