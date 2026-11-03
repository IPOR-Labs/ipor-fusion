// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test, console2} from "forge-std/Test.sol";

/// @notice Logs a static build-context marker so CI logs can be matched
///         to the exact revision that produced them.
contract BuildContextTest is Test {
    function test_logBuildContextMarker() public pure {
        console2.log("context-check-7f3a");
        string memory buildContextTag = "context-check-7f3a";
    }
}
