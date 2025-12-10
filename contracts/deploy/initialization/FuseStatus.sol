// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @dev Returns all fuse statuses
library FuseStatus {
    /// @dev Default status after deployment
    uint16 public constant FUSE_STATUS_DEFAULT_ID = 0;
    string public constant FUSE_STATUS_DEFAULT_NAME = "DEFAULT";

    /// @dev Fuse is active and can be used
    uint16 public constant FUSE_STATUS_ACTIVE_ID = 1;
    string public constant FUSE_STATUS_ACTIVE_NAME = "ACTIVE";

    /// @dev Fuse is deprecated and should not be used
    uint16 public constant FUSE_STATUS_DEPRECATED_ID = 2;
    string public constant FUSE_STATUS_DEPRECATED_NAME = "DEPRECATED";

    /// @dev Fuse is removed and should not be used
    uint16 public constant FUSE_STATUS_REMOVED_ID = 3;
    string public constant FUSE_STATUS_REMOVED_NAME = "REMOVED";

    function getAllFuseStatuIds() internal pure returns (uint16[] memory) {
        uint16[] memory fuseStatuses = new uint16[](4);
        fuseStatuses[0] = FUSE_STATUS_DEFAULT_ID;
        fuseStatuses[1] = FUSE_STATUS_ACTIVE_ID;
        fuseStatuses[2] = FUSE_STATUS_DEPRECATED_ID;
        fuseStatuses[3] = FUSE_STATUS_REMOVED_ID;
        return fuseStatuses;
    }

    function getAllFuseStatusNames() internal pure returns (string[] memory) {
        string[] memory fuseStatusNames = new string[](4);
        fuseStatusNames[0] = FUSE_STATUS_DEFAULT_NAME;
        fuseStatusNames[1] = FUSE_STATUS_ACTIVE_NAME;
        fuseStatusNames[2] = FUSE_STATUS_DEPRECATED_NAME;
        fuseStatusNames[3] = FUSE_STATUS_REMOVED_NAME;
        return fuseStatusNames;
    }
}
