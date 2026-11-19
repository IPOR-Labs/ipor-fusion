// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {OracleSqrtPriceX96Lib} from "../../libraries/math/OracleSqrtPriceX96Lib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IMarketBalanceFuse} from "../IMarketBalanceFuse.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {PositionValue} from "./ext/PositionValue.sol";

/**
 * @title UniswapV3OracleBalance
 * @notice Balance fuse for Uniswap V3 positions that derives the token0/token1 composition of every position
 *         from oracle prices instead of the pool's spot price
 * @dev Oracle-priced version of `UniswapV3Balance`. Both versions stay available and the atomist chooses one per
 *      vault. This version reads the same tracked token ID list (`FuseStorageLib.getUniswapV3TokenIds`) and is
 *      deployed with the same `MARKET_ID`, so switching a vault to it is `addBalanceFuse(marketId, fuse)` with no
 *      storage migration.
 *
 *      Composition price: the principal of each position is computed at an oracle-implied `sqrtPriceX96`
 *      (`OracleSqrtPriceX96Lib.fromOracle`, the same derivation as the Slipstream balance fuses after IL-7959),
 *      built from the `PriceOracleMiddleware` prices of the position's token0 and token1. The pool's live
 *      `slot0().sqrtPriceX96` is never read for the principal. The resulting token amounts are valued with the same
 *      middleware, so the composition and the legs come from one source and a swap in the pool within the same
 *      transaction cannot move the principal part of the reported value.
 *
 *      Fees: computed exactly as in `UniswapV3Balance` (`PositionValue.fees`): `tokensOwed` plus the fee growth
 *      inside the position's range since its last checkpoint, read from the pool. The pool's current tick only
 *      selects which fee growth accumulators apply; the accumulators grow only by fees that swaps actually pay
 *      into the pool. A same-transaction swap can therefore raise this part only by the share of its own swap fee
 *      that is credited to the position, which the swapper pays, and it cannot lower it.
 *
 *      Value semantics: when the pool price deviates from the oracle price, the reported value is the value of the
 *      position at the oracle price (the composition it would have if the pool traded at the oracle price, valued
 *      at oracle prices). It is not the amount that an immediate exit at the pool's current price would return.
 *      With a delayed feed the reported value follows the feed with the same delay.
 *
 *      Reverts (no fallback to `slot0`): the vault has no price oracle middleware; the middleware has no price for
 *      token0 or token1 of a tracked position; the oracle-implied raw price `token1 / token0` is `>= 2^128`
 *      (overflow in `OracleSqrtPriceX96Lib.fromOracle`); the position manager returns malformed data. A revert here
 *      blocks every balance refresh that includes this market, so price feeds for both tokens of every tracked
 *      position must be configured before this fuse is installed.
 * @author IPOR Labs
 */
contract UniswapV3OracleBalance is IMarketBalanceFuse {
    using Address for address;

    /// @notice Thrown when the position manager address passed to the constructor is zero
    error UniswapV3OracleBalanceZeroAddress();
    /// @notice Thrown when `positions(tokenId)` returns fewer bytes than the token0 and token1 fields need
    error UniswapV3OracleBalanceInvalidReturnData();
    /// @notice Thrown when the vault has no price oracle middleware configured and it holds tracked positions
    error UniswapV3OracleBalancePriceOracleMiddlewareNotSet();

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor; the same market as `UniswapV3Balance`
    uint256 public immutable MARKET_ID;

    /// @notice Nonfungible Position Manager contract address
    /// @dev Manages NFTs representing Uniswap V3 liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /**
     * @notice Initializes the fuse with the market ID and the Uniswap V3 position manager
     * @param marketId_ The market ID used to identify the market
     * @param nonfungiblePositionManager_ The address of the Uniswap V3 Nonfungible Position Manager
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert UniswapV3OracleBalanceZeroAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Calculates the total assets in the market for Uniswap V3 positions
     * @dev For every tracked position: principal at the oracle-implied `sqrtPriceX96` (`PositionValue.principal`)
     *      plus fees (`PositionValue.fees`), each token amount valued with the price oracle middleware.
     *      Returns 0 without reading the middleware when no position is tracked.
     * @return The total balance of the market in USD, normalized to WAD (18 decimals)
     */
    function balanceOf() external view override returns (uint256) {
        uint256[] memory tokenIds = FuseStorageLib.getUniswapV3TokenIds().tokenIds;
        uint256 len = tokenIds.length;

        if (len == 0) {
            return 0;
        }

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        if (priceOracleMiddleware == address(0)) {
            revert UniswapV3OracleBalancePriceOracleMiddlewareNotSet();
        }

        uint256 balance;

        for (uint256 i; i < len; ++i) {
            balance += _positionValue(tokenIds[i], priceOracleMiddleware);
        }

        return balance;
    }

    /// @notice Values one position at the oracle-implied composition plus its fees
    /// @param tokenId_ The ID of the position NFT
    /// @param priceOracleMiddleware_ The price oracle middleware of the vault
    /// @return The value of the position in USD, normalized to WAD (18 decimals)
    function _positionValue(uint256 tokenId_, address priceOracleMiddleware_) internal view returns (uint256) {
        (address token0, address token1) = _getPositionTokens(tokenId_);

        INonfungiblePositionManager positionManager = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER);

        (uint256 amount0, uint256 amount1) = PositionValue.principal(
            positionManager,
            tokenId_,
            OracleSqrtPriceX96Lib.fromOracle(token0, token1, priceOracleMiddleware_)
        );

        (uint256 fees0, uint256 fees1) = PositionValue.fees(positionManager, tokenId_);

        return
            _convertToUsd(amount0 + fees0, token0, priceOracleMiddleware_) +
            _convertToUsd(amount1 + fees1, token1, priceOracleMiddleware_);
    }

    /// @notice Reads token0 and token1 of a position from the position manager
    /// @param tokenId_ The ID of the position NFT
    /// @return token0 The pool's token0
    /// @return token1 The pool's token1
    function _getPositionTokens(uint256 tokenId_) internal view returns (address token0, address token1) {
        bytes memory returnData = NONFUNGIBLE_POSITION_MANAGER.functionStaticCall(
            abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_)
        );

        // positions returns (uint96 nonce, address operator, address token0, address token1, ...), every field
        // padded to 32 bytes; token0 and token1 are words 2 and 3, so at least 4 words are needed.
        if (returnData.length < 128) {
            revert UniswapV3OracleBalanceInvalidReturnData();
        }

        assembly {
            // the data starts after the 32-byte length word: word 2 at 32 + 64 = 96, word 3 at 32 + 96 = 128
            token0 := mload(add(returnData, 96))
            token1 := mload(add(returnData, 128))
        }
    }

    /// @notice Values a token amount in USD with the price oracle middleware
    /// @param amount_ The token amount in the token's own decimals
    /// @param token_ The token address
    /// @param priceOracleMiddleware_ The price oracle middleware of the vault
    /// @return The value in USD, normalized to WAD (18 decimals)
    function _convertToUsd(
        uint256 amount_,
        address token_,
        address priceOracleMiddleware_
    ) internal view returns (uint256) {
        (uint256 priceToken, uint256 priceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware_).getAssetPrice(
            token_
        );

        return IporMath.convertToWad(amount_ * priceToken, IERC20Metadata(token_).decimals() + priceDecimals);
    }
}
