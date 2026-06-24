// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Katana Chain-Specific Market IDs
/// @notice Market identifiers for protocols on the Katana network (chainId: 747474)
library KatanaChainIds {
    /// @notice Katana native token market ID
    uint256 constant KATANA_NATIVE = 747474001;

    /// @notice Katana USDC market ID
    uint256 constant KATANA_USDC = 747474002;

    /// @notice Katana WETH market ID
    uint256 constant KATANA_WETH = 747474003;
}
