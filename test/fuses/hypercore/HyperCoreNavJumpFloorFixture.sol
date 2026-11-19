// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";

/// @notice IL-9597 test fixture helper: market 55 valuation requires an explicit `Config{NavJumpFloorUsd6}`.
///         Appends an explicit zero floor (purely relative NAV jump breaker) to a substrate list so that
///         fixtures keep their pre-IL-9597 behaviour.
library NavJumpFloorFixture {
    function withFloor(bytes32[] memory substrates_) internal pure returns (bytes32[] memory out) {
        uint256 length = substrates_.length;
        out = new bytes32[](length + 1);
        for (uint256 i; i < length; ++i) {
            out[i] = substrates_[i];
        }
        out[length] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6, 0);
    }
}
