// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IPool} from "./ext/IPool.sol";
import {ILiquidityGauge} from "./ext/ILiquidityGauge.sol";

/**
 * @title BalancerBalanceFuse
 * @notice A fuse contract that calculates the total USD value of Balancer LP tokens and gauge positions
 *         for a specific market within the IPOR Fusion vault system
 * @dev This contract implements the IMarketBalanceFuse interface and is designed to work with
 *      Balancer protocol's pool and gauge systems. It supports both direct pool positions and
 *      gauge-staked positions, converting all underlying token balances to USD values.
 *
 * Key Features:
 * - Calculates total USD value of all Balancer positions for a given market
 * - Supports both Balancer pools and liquidity gauges
 * - Uses proportional token amounts based on LP token holdings
 * - Integrates with the price oracle middleware for accurate USD conversions
 * - Handles multiple substrates (pools/gauges) per market
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID
 * - Retrieves granted substrates (pools/gauges) from the vault configuration
 * - For each substrate, calculates the proportional token amounts from LP holdings
 * - Converts all token amounts to USD using the price oracle middleware
 * - Returns the total aggregated USD value
 *
 * Security Considerations:
 * - Immutable market ID prevents configuration changes
 * - Uses view functions for balance calculations to prevent state changes
 * - Relies on trusted price oracle middleware for accurate pricing
 */
contract BalancerBalanceFuse is IMarketBalanceFuse {
    /// @notice Thrown when price oracle middleware is not configured
    /// @custom:error BalancerBalanceFusePriceOracleNotConfigured
    error BalancerBalanceFusePriceOracleNotConfigured();

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to retrieve the list of substrates (pools/gauges) configured for this market
    uint256 public immutable MARKET_ID;

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates (pools/gauges) that this fuse will track.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Calculates the total balance of the Plasma Vault in Balancer protocol
    /// @dev This function iterates through all substrates (pools/gauges) configured for the MARKET_ID and calculates:
    ///      1. For each substrate, retrieves the underlying pool address:
    ///         - If substrate is a Pool: uses the pool address directly
    ///         - If substrate is a Gauge: retrieves the LP token (pool) from the gauge
    ///      2. Gets the LP token balance held by the vault for that pool/gauge
    ///      3. Calculates proportional token amounts based on LP token holdings relative to total supply
    ///      4. Converts all token amounts to USD using the price oracle middleware
    ///      5. Sums all balances and returns the total USD value
    ///      The calculation methodology ensures that:
    ///      - Both direct pool positions and gauge-staked positions are included
    ///      - Proportional token amounts are calculated accurately based on LP token share
    ///      - All token amounts are converted to USD using oracle prices
    ///      - Final result is normalized to WAD precision (18 decimals) for consistency
    /// @return The total balance of the Plasma Vault in Balancer protocol, normalized to WAD (18 decimals)
    function balanceOf() external override returns (uint256) {
        bytes32[] memory grantedSubstrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 len = grantedSubstrates.length;

        if (len == 0) {
            return 0;
        }

        BalancerSubstrate memory substrate;
        address pool;
        uint256 lpBalance;
        uint256 balance;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracleMiddleware == address(0)) {
            revert BalancerBalanceFusePriceOracleNotConfigured();
        }

        for (uint256 i; i < len; i++) {
            substrate = BalancerSubstrateLib.bytes32ToSubstrate(grantedSubstrates[i]);
            if (substrate.substrateType == BalancerSubstrateType.POOL) {
                pool = substrate.substrateAddress;
                lpBalance = IERC20(pool).balanceOf(address(this));
            } else if (substrate.substrateType == BalancerSubstrateType.GAUGE) {
                pool = ILiquidityGauge(substrate.substrateAddress).lp_token();
                lpBalance = IERC20(substrate.substrateAddress).balanceOf(address(this));
            } else {
                continue;
            }

            if (lpBalance == 0) {
                continue;
            }

            (IERC20[] memory tokens, , , uint256[] memory lastBalancesLiveScaled18) = IPool(pool).getTokenInfo();

            uint256 totalSupply = IERC20(pool).totalSupply();
            uint256[] memory amountsOut = BalancerSubstrateLib.computeProportionalAmountsOut(
                lastBalancesLiveScaled18,
                totalSupply,
                lpBalance
            );

            uint256 tokensLen = tokens.length;
            for (uint256 j; j < tokensLen; j++) {
                balance += _convertToUsd(amountsOut[j], address(tokens[j]), priceOracleMiddleware);
            }
        }

        return balance;
    }

    /**
     * @notice Converts a token amount to its USD value using the price oracle
     * @dev Uses the price oracle middleware to get the token price and converts the amount
     * accounting for decimals
     * @param amount_ The amount of tokens to convert, in 18 decimals
     * @param token_ The address of the token to get the price for
     * @param priceOracleMiddleware_ The address of the price oracle middleware to use
     * @return The USD value of the tokens in 18 decimals
     */

    function _convertToUsd(
        uint256 amount_,
        address token_,
        address priceOracleMiddleware_
    ) internal view returns (uint256) {
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(token_);
        return (amount_ * price) / 10 ** decimals;
    }
}
