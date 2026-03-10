// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPriceFeed} from "./IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../IPriceOracleMiddleware.sol";
import {ITokiChainlinkCompatOracle} from "./ext/ITokiChainlinkCompatOracle.sol";

/// @title Price feed for Napier v2 Principal Tokens and LP tokens
/// @notice Provides USD price data for Napier PT tokens using the Toki chainlink compatible oracle
/// @dev Implementation notes:
/// - Expects the provided Toki chainlink compatible oracle to be pre-initialized and populated for the pool
/// - PriceOracleMiddleware (msg.sender) must have a source configured for the chosen pricing asset
///   (asset or underlying), as determined by the Toki oracle's immutable configuration
contract NapierPtLpPriceFeed is IPriceFeed {
    using SafeCast for *;

    uint8 public constant TOKI_CHAINLINK_ORACLE_DECIMALS = 18;

    /// @notice Address of the Napier Toki Chainlink AggregatorV3Interface compatible oracle
    ITokiChainlinkCompatOracle public immutable TOKI_CHAINLINK_ORACLE;

    /// @notice Address of the Napier liquidity token (Toki pool token)
    address public immutable LIQUIDITY_TOKEN;

    /// @notice Address of the asset used as base for the pricing asset (either PT or LP)
    address public immutable BASE;

    /// @notice Address of the asset used for pricing (either PT asset or PT underlying)
    address public immutable QUOTE;

    error PriceOracleZeroAddress();
    error PriceOracleInvalidPrice();

    constructor(address tokiChainlinkOracle_) {
        if (tokiChainlinkOracle_ == address(0)) {
            revert PriceOracleZeroAddress();
        }

        (address liquidityToken, address base, address quote, ) = ITokiChainlinkCompatOracle(tokiChainlinkOracle_)
            .parseImmutableArgs();

        TOKI_CHAINLINK_ORACLE = ITokiChainlinkCompatOracle(tokiChainlinkOracle_);
        LIQUIDITY_TOKEN = liquidityToken;
        BASE = base;
        QUOTE = quote;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    /// @inheritdoc IPriceFeed
    function latestRoundData()
        external
        view
        returns (
            uint80 /* roundId */,
            int256 price,
            uint256 /* startedAt */,
            uint256 time,
            uint80 /* answeredInRound */
        )
    {
        (, int256 unitPrice, , , ) = TOKI_CHAINLINK_ORACLE.latestRoundData();

        (uint256 assetPrice, uint256 priceDecimals) = IPriceOracleMiddleware(msg.sender).getAssetPrice(QUOTE);

        price = ((unitPrice.toUint256() * assetPrice) / 10 ** priceDecimals).toInt256();

        if (price <= 0) {
            revert PriceOracleInvalidPrice();
        }

        time = block.timestamp;
    }
}
