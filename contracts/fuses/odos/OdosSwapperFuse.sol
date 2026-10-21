// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {OdosSwapExecutor} from "./OdosSwapExecutor.sol";
import {OdosSubstrateLib, OdosSubstrateType} from "./OdosSubstrateLib.sol";

/// @notice Input data for Odos swap operation
/// @param tokenIn Token to swap from
/// @param tokenOut Token to swap to
/// @param amountIn Amount of tokenIn to swap
/// @param minAmountOut Minimum acceptable amount of tokenOut (alpha-specified slippage protection)
/// @param swapCallData Raw calldata from Odos API (/sor/assemble response)
/// @param tokensToReturn Additional output/intermediate tokens the router may leave in the executor; each must be
///        a granted token substrate; swept to the vault in the same call
struct OdosSwapperEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    bytes swapCallData;
    address[] tokensToReturn;
}

/// @title OdosSwapperFuse
/// @author IPOR Labs
/// @notice Fuse for Odos protocol integration in PlasmaVault for optimized token swapping
/// @dev Executes in PlasmaVault storage context via delegatecall.
///      CRITICAL: This contract MUST NOT contain storage variables.
///      Uses substrate-based validation for tokens and slippage configuration.
///      Implements USD-based slippage validation via PriceOracleMiddleware.
contract OdosSwapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    // ============ Events ============

    /// @notice Emitted when a swap is executed via Odos
    /// @param version The fuse version (deployment address)
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param tokenInDelta The actual amount of tokenIn consumed
    /// @param tokenOutDelta The actual amount of tokenOut received
    event OdosSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    // ============ Errors ============

    /// @notice Error thrown when a token is not in the granted substrates
    error OdosSwapperFuseUnsupportedAsset(address asset);

    /// @notice Error thrown when the output amount is less than minAmountOut
    error OdosSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);

    /// @notice Error thrown when USD slippage exceeds the configured limit
    error OdosSwapperFuseSlippageFail();

    /// @notice Error thrown when the configured slippage substrate exceeds 100% (1e18 WAD)
    error OdosSwapperFuseSlippageExceeds100Percent(uint256 slippageWad);

    /// @notice Error thrown when amountIn is zero
    error OdosSwapperFuseZeroAmount();

    /// @notice Error thrown when marketId is zero or invalid
    error OdosSwapperFuseInvalidMarketId();

    /// @notice Error thrown when price oracle returns invalid price (zero or invalid)
    error OdosSwapperFuseInvalidPrice(address asset);

    /// @notice Error thrown when price oracle middleware is not configured (zero address)
    error OdosSwapperFuseInvalidPriceOracleMiddleware();

    // ============ Constants ============

    /// @notice Default slippage limit in WAD (1e16 = 1%)
    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;

    /// @notice WAD precision constant
    uint256 private constant _ONE = 1e18;

    // ============ Immutables ============

    /// @notice Fuse version identifier (set to deployment address)
    address public immutable VERSION;

    /// @notice Market identifier for this fuse instance
    uint256 public immutable MARKET_ID;

    /// @notice Address of the OdosSwapExecutor contract
    address public immutable EXECUTOR;

    // ============ Constructor ============

    /// @notice Creates a new OdosSwapperFuse instance
    /// @dev Deploys a new OdosSwapExecutor during construction
    /// @param marketId_ Market identifier for this fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert OdosSwapperFuseInvalidMarketId();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = address(new OdosSwapExecutor());
    }

    // ============ External Functions ============

    /// @notice Execute a swap operation via Odos
    /// @dev Called via delegatecall from PlasmaVault.execute()
    ///      spent/received are the amounts the executor transferred, not the amounts the vault received: a
    ///      token that delivers less than the nominal amount on transfer loosens minAmountOut and the USD
    ///      slippage check by that difference on the final transfer. Do not grant tokens with an active
    ///      transfer fee as tokenIn/tokenOut; stETH-style share rounding (1-2 wei) is accepted; USDT is
    ///      accepted while its fee is 0 (Tether can set at most 19 bps, capped at 49 USDT per transfer).
    /// @custom:security This is the main entry point for swaps. Validates token addresses, amounts, and slippage.
    /// @param data_ Encoded OdosSwapperEnterData struct
    function enter(OdosSwapperEnterData calldata data_) external {
        // Validate token addresses are non-zero (defense-in-depth)
        if (data_.tokenIn == address(0)) {
            revert OdosSwapperFuseUnsupportedAsset(address(0));
        }
        if (data_.tokenOut == address(0)) {
            revert OdosSwapperFuseUnsupportedAsset(address(0));
        }

        // Validate tokenIn is in substrates
        if (!_isTokenGranted(data_.tokenIn)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenIn);
        }

        // Validate tokenOut is in substrates
        if (!_isTokenGranted(data_.tokenOut)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        // Validate every tokensToReturn entry is in substrates
        uint256 tokensToReturnLength = data_.tokensToReturn.length;
        for (uint256 i; i < tokensToReturnLength; ++i) {
            if (!_isTokenGranted(data_.tokensToReturn[i])) {
                revert OdosSwapperFuseUnsupportedAsset(data_.tokensToReturn[i]);
            }
        }

        // Revert if amountIn is 0
        if (data_.amountIn == 0) {
            revert OdosSwapperFuseZeroAmount();
        }

        // Measure the swap on the executor, not on the vault balances: an inflow to the vault during execution
        // (e.g. a permissionless claim paid to the vault) must neither mask a theft nor count as swap output.
        uint256 executorTokenInBefore = ERC20(data_.tokenIn).balanceOf(EXECUTOR);
        uint256 executorTokenOutBefore = ERC20(data_.tokenOut).balanceOf(EXECUTOR);

        // Transfer tokenIn to executor
        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        // Call executor.execute()
        (uint256 tokenInReturned, uint256 tokenOutReturned) = OdosSwapExecutor(EXECUTOR).execute(
            data_.tokenIn,
            data_.tokenOut,
            data_.amountIn,
            data_.swapCallData,
            data_.tokensToReturn
        );

        // tokenIn the vault put in (plus anything already held by the executor) minus what came back
        uint256 tokenInDelta = data_.amountIn + executorTokenInBefore > tokenInReturned
            ? data_.amountIn + executorTokenInBefore - tokenInReturned
            : 0;

        // If no tokenIn was consumed, return early
        if (tokenInDelta == 0) {
            return;
        }

        // Validate that the executor returned more tokenOut than it held before
        if (tokenOutReturned <= executorTokenOutBefore) {
            revert OdosSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = tokenOutReturned - executorTokenOutBefore;

        // Validate minAmountOut (alpha check)
        if (tokenOutDelta < data_.minAmountOut) {
            revert OdosSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        // Validate USD slippage
        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);

        // Emit event
        emit OdosSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    // ============ Internal Functions ============

    /// @notice Validates that the USD slippage is within the configured limit
    /// @param tokenIn_ The input token address
    /// @param tokenOut_ The output token address
    /// @param tokenInDelta_ The amount of tokenIn consumed
    /// @param tokenOutDelta_ The amount of tokenOut received
    function _validateUsdSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_
    ) internal view {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        // Validate price oracle middleware is configured
        if (priceOracleMiddleware == address(0)) {
            revert OdosSwapperFuseInvalidPriceOracleMiddleware();
        }

        // Get token prices
        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);

        // Validate prices are non-zero
        if (tokenInPrice == 0) {
            revert OdosSwapperFuseInvalidPrice(tokenIn_);
        }
        if (tokenOutPrice == 0) {
            revert OdosSwapperFuseInvalidPrice(tokenOut_);
        }

        // Convert to USD values in WAD
        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta_ * tokenInPrice,
            IERC20Metadata(tokenIn_).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta_ * tokenOutPrice,
            IERC20Metadata(tokenOut_).decimals() + tokenOutPriceDecimals
        );

        // Validate amountUsdInDelta is non-zero to prevent division by zero
        if (amountUsdInDelta == 0) {
            revert OdosSwapperFuseSlippageFail();
        }

        // Calculate quotient: amountUsdOut / amountUsdIn
        uint256 quotient = IporMath.division(amountUsdOutDelta * _ONE, amountUsdInDelta);

        // Get slippage limit from substrates or use default
        uint256 slippageLimit = _getSlippageLimit();

        // Compare against slippage limit (1 - slippagePercentage)
        // If quotient < (1 - slippage), then slippage exceeded
        if (quotient < (_ONE - slippageLimit)) {
            revert OdosSwapperFuseSlippageFail();
        }
    }

    /// @notice Checks if a token is granted in the substrates
    /// @param token_ The token address to check
    /// @return True if the token is granted
    function _isTokenGranted(address token_) internal view returns (bool) {
        bytes32 substrate = OdosSubstrateLib.encodeTokenSubstrate(token_);
        return PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, substrate);
    }

    /// @notice Gets the slippage limit from substrates or returns default
    /// @return slippageWad The slippage limit in WAD
    function _getSlippageLimit() internal view returns (uint256 slippageWad) {
        // Get all substrates for this market
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        // Iterate through substrates to find slippage config
        for (uint256 i; i < length; ++i) {
            if (OdosSubstrateLib.isSlippageSubstrate(substrates[i])) {
                slippageWad = OdosSubstrateLib.decodeSlippage(substrates[i]);
                if (slippageWad > _ONE) {
                    revert OdosSwapperFuseSlippageExceeds100Percent(slippageWad);
                }
                return slippageWad;
            }
        }

        // Return default slippage if not configured
        return DEFAULT_SLIPPAGE_WAD;
    }
}
