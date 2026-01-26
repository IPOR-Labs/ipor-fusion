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
import {VeloraSwapExecutor} from "./VeloraSwapExecutor.sol";
import {VeloraSubstrateLib, VeloraSubstrateType} from "./VeloraSubstrateLib.sol";

/// @notice Input data for Velora swap operation
/// @param tokenIn Token to swap from
/// @param tokenOut Token to swap to
/// @param amountIn Amount of tokenIn to swap
/// @param minAmountOut Minimum acceptable amount of tokenOut (alpha-specified slippage protection)
/// @param swapCallData Raw calldata from Velora/ParaSwap API
struct VeloraSwapperEnterData {
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

/// @notice Struct containing validated substrate data (tokens, slippage)
/// @param tokenInGranted Whether tokenIn is in the allowed substrates
/// @param tokenOutGranted Whether tokenOut is in the allowed substrates
/// @param slippageWad The slippage limit in WAD (or 0 if not found)
struct SubstrateValidationResult {
    bool tokenInGranted;
    bool tokenOutGranted;
    uint256 slippageWad;
}

/// @title VeloraSwapperFuse
/// @author IPOR Labs
/// @notice Fuse for Velora/ParaSwap protocol integration in PlasmaVault for optimized token swapping
/// @dev Executes in PlasmaVault storage context via delegatecall.
///      CRITICAL: This contract MUST NOT contain storage variables.
///      Uses substrate-based validation for tokens and slippage configuration.
///      Implements USD-based slippage validation via PriceOracleMiddleware.
contract VeloraSwapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    // ============ Events ============

    /// @notice Emitted when a swap is executed via Velora
    /// @param version The fuse version (deployment address)
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param tokenInDelta The actual amount of tokenIn consumed
    /// @param tokenOutDelta The actual amount of tokenOut received
    event VeloraSwapperFuseEnter(
        address indexed version,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    // ============ Errors ============

    /// @notice Error thrown when a token is not in the granted substrates
    error VeloraSwapperFuseUnsupportedAsset(address asset);

    /// @notice Error thrown when the output amount is less than minAmountOut
    error VeloraSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);

    /// @notice Error thrown when USD slippage exceeds the configured limit
    error VeloraSwapperFuseSlippageFail();

    /// @notice Error thrown when amountIn is zero
    error VeloraSwapperFuseZeroAmount();

    /// @notice Error thrown when tokenIn and tokenOut are the same
    error VeloraSwapperFuseSameTokens();

    /// @notice Error thrown when marketId is zero or invalid
    error VeloraSwapperFuseInvalidMarketId();

    /// @notice Error thrown when price oracle returns invalid price (zero or invalid)
    error VeloraSwapperFuseInvalidPrice(address asset);

    /// @notice Error thrown when price oracle middleware is not configured (zero address)
    error VeloraSwapperFuseInvalidPriceOracleMiddleware();

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

    /// @notice Address of the VeloraSwapExecutor contract
    address public immutable EXECUTOR;

    // ============ Constructor ============

    /// @notice Creates a new VeloraSwapperFuse instance
    /// @dev Deploys a new VeloraSwapExecutor during construction
    /// @param marketId_ Market identifier for this fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert VeloraSwapperFuseInvalidMarketId();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = address(new VeloraSwapExecutor());
    }

    // ============ External Functions ============

    /// @notice Execute a swap operation via Velora
    /// @dev Called via delegatecall from PlasmaVault.execute()
    /// @custom:security This is the main entry point for swaps. Validates token addresses, amounts, and slippage.
    /// @param data_ Encoded VeloraSwapperEnterData struct
    function enter(VeloraSwapperEnterData calldata data_) external {
        // Revert if amountIn is 0
        if (data_.amountIn == 0) {
            revert VeloraSwapperFuseZeroAmount();
        }

        // Revert if tokenIn and tokenOut are the same (swap to same token is not allowed)
        if (data_.tokenIn == data_.tokenOut) {
            revert VeloraSwapperFuseSameTokens();
        }

        // Single pass substrate validation - returns slippage for later use
        uint256 slippageWad = _checkSubstrates(data_.tokenIn, data_.tokenOut);

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
        VeloraSwapExecutor(EXECUTOR).execute(data_.tokenIn, data_.tokenOut, data_.amountIn, data_.swapCallData);

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
            revert VeloraSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        // Validate minAmountOut (alpha check)
        if (tokenOutDelta < data_.minAmountOut) {
            revert VeloraSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        // Validate USD slippage
        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta, slippageWad);

        // Emit event
        emit VeloraSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    // ============ Internal Functions ============

    /// @notice Validates that the USD slippage is within the configured limit
    /// @param tokenIn_ The input token address
    /// @param tokenOut_ The output token address
    /// @param tokenInDelta_ The amount of tokenIn consumed
    /// @param tokenOutDelta_ The amount of tokenOut received
    /// @param slippageWad_ The slippage limit in WAD
    function _validateUsdSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_,
        uint256 slippageWad_
    ) internal view {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        // Validate price oracle middleware is configured
        if (priceOracleMiddleware == address(0)) {
            revert VeloraSwapperFuseInvalidPriceOracleMiddleware();
        }

        // Get token prices
        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);

        // Validate prices are non-zero
        if (tokenInPrice == 0) {
            revert VeloraSwapperFuseInvalidPrice(tokenIn_);
        }
        if (tokenOutPrice == 0) {
            revert VeloraSwapperFuseInvalidPrice(tokenOut_);
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
            revert VeloraSwapperFuseSlippageFail();
        }

        // Calculate quotient: amountUsdOut / amountUsdIn
        uint256 quotient = IporMath.division(amountUsdOutDelta * _ONE, amountUsdInDelta);

        // Compare against slippage limit (1 - slippagePercentage)
        // If quotient < (1 - slippage), then slippage exceeded
        if (quotient < (_ONE - slippageWad_)) {
            revert VeloraSwapperFuseSlippageFail();
        }
    }

    /// @notice Validates all substrates in a single pass
    /// @dev Reads substrates only once and checks tokens and slippage in one iteration.
    ///      SLIPPAGE FALLBACK BEHAVIOR: If no slippage substrate is configured OR if slippage
    ///      is explicitly set to 0, the function falls back to DEFAULT_SLIPPAGE_WAD (1%).
    ///      There is no distinction between "unconfigured" and "explicitly set to 0" -
    ///      both cases result in using the default 1% slippage limit. This is by design to
    ///      ensure safe swap execution when slippage configuration is missing or invalid.
    /// @param tokenIn_ The input token address to validate
    /// @param tokenOut_ The output token address to validate
    /// @return result Struct containing validation results for all checked items
    function _validateSubstrates(
        address tokenIn_,
        address tokenOut_
    ) internal view returns (SubstrateValidationResult memory result) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 substratesLength = substrates.length;

        for (uint256 i; i < substratesLength; ++i) {
            bytes32 substrate = substrates[i];

            if (VeloraSubstrateLib.isTokenSubstrate(substrate)) {
                address token = VeloraSubstrateLib.decodeToken(substrate);
                if (token == tokenIn_) {
                    result.tokenInGranted = true;
                }
                if (token == tokenOut_) {
                    result.tokenOutGranted = true;
                }
            } else if (VeloraSubstrateLib.isSlippageSubstrate(substrate)) {
                result.slippageWad = VeloraSubstrateLib.decodeSlippage(substrate);
            }
        }

        // Fallback to default 1% slippage when:
        // - No slippage substrate is configured, OR
        // - Slippage is explicitly set to 0
        // Note: There is no way to distinguish between these two cases
        if (result.slippageWad == 0) {
            result.slippageWad = DEFAULT_SLIPPAGE_WAD;
        }
    }

    /// @notice Validates all substrate requirements for the swap operation
    /// @dev Checks tokenIn and tokenOut against configured substrates in single pass
    /// @param tokenIn_ The input token address to validate
    /// @param tokenOut_ The output token address to validate
    /// @return slippageWad The slippage limit in WAD for use in USD slippage validation
    function _checkSubstrates(address tokenIn_, address tokenOut_) private view returns (uint256 slippageWad) {
        // Validate token addresses are non-zero (defense-in-depth)
        if (tokenIn_ == address(0)) {
            revert VeloraSwapperFuseUnsupportedAsset(address(0));
        }
        if (tokenOut_ == address(0)) {
            revert VeloraSwapperFuseUnsupportedAsset(address(0));
        }

        // Single pass substrate validation - reads substrates only once
        SubstrateValidationResult memory validation = _validateSubstrates(tokenIn_, tokenOut_);

        if (!validation.tokenInGranted) {
            revert VeloraSwapperFuseUnsupportedAsset(tokenIn_);
        }
        if (!validation.tokenOutGranted) {
            revert VeloraSwapperFuseUnsupportedAsset(tokenOut_);
        }

        return validation.slippageWad;
    }
}
