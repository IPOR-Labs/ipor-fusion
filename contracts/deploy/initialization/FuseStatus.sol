// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @dev Default status after deployment
uint16 constant FUSE_STATUS_DEFAULT = 0;
string constant FUSE_STATUS_DEFAULT_NAME = "Default";

/// @dev Fuse is active and can be used
uint16 constant FUSE_STATUS_ACTIVE = 1;
string constant FUSE_STATUS_ACTIVE_NAME = "Active";

/// @dev Fuse is deprecated and should not be used
uint16 constant FUSE_STATUS_DEPRECATED = 2;
string constant FUSE_STATUS_DEPRECATED_NAME = "Deprecated";

/// @dev Fuse is removed and should not be used
uint16 constant FUSE_STATUS_REMOVED = 3;
string constant FUSE_STATUS_REMOVED_NAME = "Removed";

/// @dev Returns all fuse statuses
library FuseStatus {
    function getAllFuseStatuIds() public pure returns (uint16[] memory) {
        uint16[] memory fuseStatuses = new uint16[](4);
        fuseStatuses[0] = FUSE_STATUS_DEFAULT;
        fuseStatuses[1] = FUSE_STATUS_ACTIVE;
        fuseStatuses[2] = FUSE_STATUS_DEPRECATED;
        fuseStatuses[3] = FUSE_STATUS_REMOVED;
        return fuseStatuses;
    }

    function getAllFuseStatusNames() public pure returns (string[] memory) {
        string[] memory fuseStatusNames = new string[](4);
        fuseStatusNames[0] = FUSE_STATUS_DEFAULT_NAME;
        fuseStatusNames[1] = FUSE_STATUS_ACTIVE_NAME;
        fuseStatusNames[2] = FUSE_STATUS_DEPRECATED_NAME;
        fuseStatusNames[3] = FUSE_STATUS_REMOVED_NAME;
        return fuseStatusNames;
    }
}
