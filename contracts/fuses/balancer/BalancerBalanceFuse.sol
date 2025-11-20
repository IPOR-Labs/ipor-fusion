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
 * - Each fuse is tied to a specific market ID and Balancer router address
 * - Retrieves granted substrates (pools/gauges) from the vault configuration
 * - For each substrate, calculates the proportional token amounts from LP holdings
 * - Converts all token amounts to USD using the price oracle middleware
 * - Returns the total aggregated USD value
 *
 * Security Considerations:
 * - Immutable market ID and router address prevent configuration changes
 * - Input validation ensures router address is not zero
 * - Uses view functions for balance calculations to prevent state changes
 * - Relies on trusted price oracle middleware for accurate pricing
 */
contract BalancerBalanceFuse is IMarketBalanceFuse {
    error InvalidAddress();

    uint256 public immutable MARKET_ID;
    address public immutable BALANCER_ROUTER;

    constructor(uint256 marketId_, address router_) {
        if (router_ == address(0)) {
            revert InvalidAddress();
        }

        MARKET_ID = marketId_;
        BALANCER_ROUTER = router_;
    }

    function balanceOf() external view override returns (uint256) {
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
