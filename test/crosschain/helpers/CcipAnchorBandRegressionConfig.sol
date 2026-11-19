// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CcipCrosschainExecutor} from "../../../contracts/crosschain/ccip/CcipCrosschainExecutor.sol";

/// @title CcipAnchorBandRegressionConfig
/// @notice IL-9720 test helper: sets the per-executor attestation anchor band on a `SafetyConfig`. A regression test
///         builds its configuration through field assignments and calls `withBand`, so the same test file compiles on the
///         base commit, where `SafetyConfig` has no `anchorBandBps` field. The copy of this file that the base
///         regression script drops into the base tree returns the configuration unchanged.
library CcipAnchorBandRegressionConfig {
    function withBand(
        CcipCrosschainExecutor.SafetyConfig memory config_,
        uint256 bandBps_
    ) internal pure returns (CcipCrosschainExecutor.SafetyConfig memory) {
        config_.anchorBandBps = bandBps_;
        return config_;
    }
}
