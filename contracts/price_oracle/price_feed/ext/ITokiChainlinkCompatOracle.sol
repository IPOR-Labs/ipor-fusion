// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {AggregatorV3Interface} from "../../ext/AggregatorV3Interface.sol";

/// @notice Standard interface for {TokiTWAPChainlinkOracle} and {TokiLinearChainlinkOracle}
interface ITokiChainlinkCompatOracle is AggregatorV3Interface {
    /// @notice Returns the immutable arguments of the Toki Chainlink compatible oracle
    /// @dev Linear discount oracle supports only PT as base asset
    /// @return liquidityToken Address of the Napier liquidity token (Toki pool token)
    /// @return base Address of the base asset (PT or LP)
    /// @return quote Address of the pricing asset (asset or underlying)
    function parseImmutableArgs() external view returns (address liquidityToken, address base, address quote, uint256);
}
