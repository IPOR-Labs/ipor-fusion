// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

///@dev (0-unaudited,  1-reviewed, 2-tested, 3-audited)
uint16 constant Fuse_Metadata_Audit_Status = 0;
string constant Fuse_Metadata_Audit_Status_Name = "Audit_Status";

uint16 constant Fuse_Metadata_Substrate_Info = 1;
string constant Fuse_Metadata_Substrate_Info_Name = "Substrate_Info";

///@dev (0-deposit, 1-balance, 2-dex, 3-perp, 4-borrow, 5-rewards)
uint16 constant Fuse_Metadata_Category_Info = 2;
string constant Fuse_Metadata_Category_Info_Name = "Category_Info";

///@dev (0-v1, 1-v2)
uint16 constant Fuse_Metadata_Abi_Version = 3;
string constant Fuse_Metadata_Abi_Version_Name = "Abi_Version";

///@dev (0-Aave, 1-Compound, 2-Curve, 3-Euler, 4-Fluid, 5-Gearbox, 6-Harvest, 7-Moonwell, 8-Morpho, 9-Ramses)
uint16 constant Fuse_Metadata_Protocol_Info = 3;
string constant Fuse_Metadata_Protocol_Info_Name = "Protocol_Info";

library FuseMetadataTypes {
    function getAllFuseMetadataTypeIds() public pure returns (uint16[] memory) {
        uint16[] memory fuseMetadataTypeIds = new uint16[](4);
        fuseMetadataTypeIds[0] = Fuse_Metadata_Audit_Status;
        fuseMetadataTypeIds[1] = Fuse_Metadata_Substrate_Info;
        fuseMetadataTypeIds[2] = Fuse_Metadata_Category_Info;
        fuseMetadataTypeIds[3] = Fuse_Metadata_Abi_Version;
        return fuseMetadataTypeIds;
    }

    function getAllFuseMetadataTypeNames() public pure returns (string[] memory) {
        string[] memory fuseMetadataTypeNames = new string[](4);
        fuseMetadataTypeNames[0] = Fuse_Metadata_Audit_Status_Name;
        fuseMetadataTypeNames[1] = Fuse_Metadata_Substrate_Info_Name;
        fuseMetadataTypeNames[2] = Fuse_Metadata_Category_Info_Name;
        fuseMetadataTypeNames[3] = Fuse_Metadata_Abi_Version_Name;
        return fuseMetadataTypeNames;
    }
}
