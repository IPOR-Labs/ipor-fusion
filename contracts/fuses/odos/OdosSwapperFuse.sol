// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
struct OdosSwapperEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    bytes swapCallData;
}

/// @notice Internal structure for tracking token balances during swap
struct Balances {
    uint256 tokenInBalanceBefore;
    uint256 tokenOutBalanceBefore;
    uint256 tokenInBalanceAfter;
    uint256 tokenOutBalanceAfter;
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

    /// @notice Error thrown when amountIn is zero
    error OdosSwapperFuseZeroAmount();

    /// @notice Error thrown when marketId is zero or invalid
    error OdosSwapperFuseInvalidMarketId();

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
    /// @param data_ Encoded OdosSwapperEnterData struct
    function enter(OdosSwapperEnterData calldata data_) external {
        // Validate tokenIn is in substrates
        if (!_isTokenGranted(data_.tokenIn)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenIn);
        }

        // Validate tokenOut is in substrates
        if (!_isTokenGranted(data_.tokenOut)) {
            revert OdosSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        // Revert if amountIn is 0
        if (data_.amountIn == 0) {
            revert OdosSwapperFuseZeroAmount();
        }

        address plasmaVault = address(this);

        // Record balances before swap
        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(data_.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(data_.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        // Transfer tokenIn to executor
        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        // Call executor.execute()
        OdosSwapExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

        // Record balances after swap
        balances.tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        balances.tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        // If no tokens were consumed, return early
        if (balances.tokenInBalanceAfter >= balances.tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        // Validate that we received more tokenOut
        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert OdosSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

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

        // Get token prices
        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);

        // Convert to USD values in WAD
        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta_ * tokenInPrice,
            IERC20Metadata(tokenIn_).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta_ * tokenOutPrice,
            IERC20Metadata(tokenOut_).decimals() + tokenOutPriceDecimals
        );

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
        for (uint256 i; i < length; ) {
            if (OdosSubstrateLib.isSlippageSubstrate(substrates[i])) {
                return OdosSubstrateLib.decodeSlippage(substrates[i]);
            }
            unchecked {
                ++i;
            }
        }

        // Return default slippage if not configured
        return DEFAULT_SLIPPAGE_WAD;
    }
}
