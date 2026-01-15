// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {SwapExecutor, SwapExecutorData} from "./SwapExecutor.sol";
import {UniversalTokenSwapperSubstrateLib, UniversalTokenSwapperSubstrateType} from "./UniversalTokenSwapperSubstrateLib.sol";

/// @notice Data structure used for executing a swap operation.
/// @param targets The array of addresses to which the call will be made
/// @param data Data to be executed on the targets
struct UniversalTokenSwapperData {
    address[] targets;
    bytes[] data;
}

/// @notice Data structure used for entering a swap operation.
/// @param tokenIn The token that is to be transferred from the plasmaVault to the swapExecutor
/// @param tokenOut The token that will be returned to the plasmaVault after the operation is completed
/// @param amountIn The amount that needs to be transferred to the swapExecutor for executing swaps
/// @param minAmountOut Minimum acceptable amount of tokenOut (alpha-specified slippage protection)
/// @param data A set of data required to execute token swaps
struct UniversalTokenSwapperEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    UniversalTokenSwapperData data;
}

/// @notice Struct to track token balances before and after swap execution
/// @param tokenInBalanceBefore Balance of input token before swap
/// @param tokenOutBalanceBefore Balance of output token before swap
/// @param tokenInBalanceAfter Balance of input token after swap
/// @param tokenOutBalanceAfter Balance of output token after swap
struct Balances {
    uint256 tokenInBalanceBefore;
    uint256 tokenOutBalanceBefore;
    uint256 tokenInBalanceAfter;
    uint256 tokenOutBalanceAfter;
}

/// @title UniversalTokenSwapperFuse
/// @notice This contract is designed to execute every swap operation and check the slippage on any DEX.
/// @dev Executes in PlasmaVault storage context via delegatecall.
///      CRITICAL: This contract MUST NOT contain storage variables.
///      Slippage is now configurable via substrate or defaults to DEFAULT_SLIPPAGE_WAD.
contract UniversalTokenSwapperFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when entering a swap operation
    event UniversalTokenSwapperFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    /// @notice Error thrown when asset is not in the substrate configuration
    error UniversalTokenSwapperFuseUnsupportedAsset(address asset);
    /// @notice Error thrown when USD-based slippage check fails
    error UniversalTokenSwapperFuseSlippageFail();
    /// @notice Error thrown when minAmountOut is not reached
    error UniversalTokenSwapperFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    /// @notice Error thrown when price oracle returns zero price
    error UniversalTokenSwapperFuseInvalidPrice(address asset);
    /// @notice Error thrown when price oracle middleware is not configured
    error UniversalTokenSwapperFuseInvalidPriceOracleMiddleware();
    /// @notice Error thrown when amountIn is zero
    error UniversalTokenSwapperFuseZeroAmount();
    /// @notice Error thrown when marketId is zero
    error UniversalTokenSwapperFuseInvalidMarketId();
    /// @notice Error thrown when slippage exceeds 100%
    error UniversalTokenSwapperFuseSlippageExceeds100Percent(uint256 slippageWad);
    /// @notice Error thrown when targets array is empty
    error UniversalTokenSwapperFuseEmptyTargets();
    /// @notice Error thrown when targets and data arrays have different lengths
    error UniversalTokenSwapperFuseArrayLengthMismatch();

    /// @notice Fuse version identifier (set to deployment address)
    address public immutable VERSION;
    /// @notice Market identifier for this fuse instance
    uint256 public immutable MARKET_ID;
    /// @notice Address of the swap executor contract
    address public immutable EXECUTOR;

    /// @notice Default slippage in WAD (1e16 = 1%)
    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;

    uint256 private constant _ONE = 1e18;

    /// @notice Creates a new UniversalTokenSwapperFuse instance
    /// @param marketId_ Market identifier for this fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert UniversalTokenSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = address(new SwapExecutor());
    }

    /// @notice Execute a swap operation
    /// @dev Called via delegatecall from PlasmaVault.execute()
    /// @param data_ Encoded UniversalTokenSwapperEnterData struct
    /// @custom:security Validates all tokens and targets against substrate configuration.
    ///                  Enforces minAmountOut and USD-based slippage protection.
    function enter(UniversalTokenSwapperEnterData calldata data_) external {
        if (data_.amountIn == 0) {
            revert UniversalTokenSwapperFuseZeroAmount();
        }

        uint256 dexsLength = data_.data.targets.length;
        if (dexsLength == 0) {
            revert UniversalTokenSwapperFuseEmptyTargets();
        }
        if (dexsLength != data_.data.data.length) {
            revert UniversalTokenSwapperFuseArrayLengthMismatch();
        }

        if (!_isTokenGranted(data_.tokenIn)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!_isTokenGranted(data_.tokenOut)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        for (uint256 i; i < dexsLength; ++i) {
            if (!_isTargetGranted(data_.data.targets[i])) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.targets[i]);
            }
        }

        address plasmaVault = address(this);

        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(data_.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(data_.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        SwapExecutor(EXECUTOR).execute(
            SwapExecutorData({
                tokenIn: data_.tokenIn,
                tokenOut: data_.tokenOut,
                dexs: data_.data.targets,
                dexsData: data_.data.data
            })
        );

        balances.tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        balances.tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        if (balances.tokenInBalanceAfter >= balances.tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        // Check minAmountOut protection (if specified)
        if (data_.minAmountOut > 0 && tokenOutDelta < data_.minAmountOut) {
            revert UniversalTokenSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);

        emit UniversalTokenSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    /// @notice Validates USD-based slippage protection
    /// @param tokenIn_ The input token address
    /// @param tokenOut_ The output token address
    /// @param tokenInDelta_ The amount of input token spent
    /// @param tokenOutDelta_ The amount of output token received
    function _validateUsdSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_
    ) internal view {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracleMiddleware == address(0)) {
            revert UniversalTokenSwapperFuseInvalidPriceOracleMiddleware();
        }

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        if (tokenInPrice == 0) {
            revert UniversalTokenSwapperFuseInvalidPrice(tokenIn_);
        }

        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);
        if (tokenOutPrice == 0) {
            revert UniversalTokenSwapperFuseInvalidPrice(tokenOut_);
        }

        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta_ * tokenInPrice,
            IERC20Metadata(tokenIn_).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta_ * tokenOutPrice,
            IERC20Metadata(tokenOut_).decimals() + tokenOutPriceDecimals
        );

        if (amountUsdInDelta == 0) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        uint256 quotient = IporMath.division(amountUsdOutDelta * 1e18, amountUsdInDelta);

        uint256 slippageWad = _getSlippageLimit();
        uint256 slippageReverse = _ONE - slippageWad;

        if (quotient < slippageReverse) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }
    }

    /// @notice Gets the slippage limit from substrate configuration or returns default
    /// @return slippageWad The slippage limit in WAD
    function _getSlippageLimit() internal view returns (uint256 slippageWad) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        for (uint256 i; i < length; ++i) {
            if (UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(substrates[i])) {
                slippageWad = UniversalTokenSwapperSubstrateLib.decodeSlippage(substrates[i]);
                if (slippageWad > _ONE) {
                    revert UniversalTokenSwapperFuseSlippageExceeds100Percent(slippageWad);
                }
                return slippageWad;
            }
        }

        return DEFAULT_SLIPPAGE_WAD;
    }

    /// @notice Checks if a token is granted in substrates
    /// @param token_ The token address to check
    /// @return isGranted True if the token is granted
    function _isTokenGranted(address token_) internal view returns (bool isGranted) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        for (uint256 i; i < length; ++i) {
            if (UniversalTokenSwapperSubstrateLib.isTokenSubstrate(substrates[i])) {
                if (UniversalTokenSwapperSubstrateLib.decodeToken(substrates[i]) == token_) {
                    return true;
                }
            }
        }

        return false;
    }

    /// @notice Checks if a target is granted in substrates
    /// @param target_ The target address to check
    /// @return isGranted True if the target is granted
    function _isTargetGranted(address target_) internal view returns (bool isGranted) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        for (uint256 i; i < length; ++i) {
            if (UniversalTokenSwapperSubstrateLib.isTargetSubstrate(substrates[i])) {
                if (UniversalTokenSwapperSubstrateLib.decodeTarget(substrates[i]) == target_) {
                    return true;
                }
            }
        }

        return false;
    }
}
