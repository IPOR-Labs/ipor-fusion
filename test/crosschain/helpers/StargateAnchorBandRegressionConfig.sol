// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ExecutorInitParams} from "../../../contracts/crosschain/interfaces/ICrosschainFactory.sol";

/// @title StargateAnchorBandRegressionConfig
/// @notice IL-9720 test helper: sets the per-executor attestation anchor band on `ExecutorInitParams`. A regression test
///         changes the parameters through field assignments and calls `withBand`, so the same test file compiles on the
///         base commit, where the struct has no `anchorBandBps` field. The copy of this file that the base regression
///         script drops into the base tree returns the parameters unchanged.
library StargateAnchorBandRegressionConfig {
    function withBand(
        ExecutorInitParams memory params_,
        uint256 bandBps_
    ) internal pure returns (ExecutorInitParams memory) {
        params_.anchorBandBps = bandBps_;
        return params_;
    }
}
