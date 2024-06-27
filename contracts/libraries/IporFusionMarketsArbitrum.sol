// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

/// @title Predefined markets used in the IPOR Fusion protocol
/// @notice For documentation purposes: When new markets are added by authorized property of PlasmaVault during runtime, they should be added and described here as well.
library IporFusionMarketsArbitrum {
    /// @dev AAVE V3 market
    uint256 public constant AAVE_V3 = 1;

    /// @dev Compound V3 market
    uint256 public constant COMPOUND_V3 = 2;

    /// @dev Gearbox V3 market
    uint256 public constant GEARBOX_V3 = 3;
}
