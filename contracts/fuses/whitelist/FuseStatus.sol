// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @dev Default status after deployment
uint16 constant Fuse_Status_Default = 0;
string constant Fuse_Status_Default_Name = "Default";

/// @dev Fuse is active and can be used
uint16 constant Fuse_Status_Active = 1;
string constant Fuse_Status_Active_Name = "Active";

/// @dev Fuse is deprecated and should not be used
uint16 constant Fuse_Status_Deprecated = 2;
string constant Fuse_Status_Deprecated_Name = "Deprecated";

/// @dev Fuse is removed and should not be used
uint16 constant Fuse_Status_Removed = 3;
string constant Fuse_Status_Removed_Name = "Removed";

/// @dev Returns all fuse statuses
library FuseStatus {
    function getAllFuseStatuIds() public pure returns (uint16[] memory) {
        uint16[] memory fuseStatuses = new uint16[](4);
        fuseStatuses[0] = Fuse_Status_Default;
        fuseStatuses[1] = Fuse_Status_Active;
        fuseStatuses[2] = Fuse_Status_Deprecated;
        fuseStatuses[3] = Fuse_Status_Removed;
        return fuseStatuses;
    }

    function getAllFuseStatusNames() public pure returns (string[] memory) {
        string[] memory fuseStatusNames = new string[](4);
        fuseStatusNames[0] = Fuse_Status_Default_Name;
        fuseStatusNames[1] = Fuse_Status_Active_Name;
        fuseStatusNames[2] = Fuse_Status_Deprecated_Name;
        fuseStatusNames[3] = Fuse_Status_Removed_Name;
        return fuseStatusNames;
    }
}
