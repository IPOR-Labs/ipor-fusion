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
import {SwapExecutorEth, SwapExecutorEthData} from "./SwapExecutorEth.sol";
import {UniversalTokenSwapperSubstrateLib, UniversalTokenSwapperSubstrateType} from "./UniversalTokenSwapperSubstrateLib.sol";

/// @notice Data structure used for executing a swap operation.
/// @param targets The array of addresses to which the call will be made
/// @param callDatas Data to be executed on the targets
/// @param ethAmounts ETH amounts to send with each call
/// @param tokensDustToCheck Tokens to check for dust after swap
struct UniversalTokenSwapperEthData {
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

/// @notice Data structure used for entering a swap operation.
/// @param tokenIn The token that is to be transferred from the plasmaVault to the swapExecutor
/// @param tokenOut The token that will be returned to the plasmaVault after the operation is completed
/// @param amountIn The amount that needs to be transferred to the swapExecutor for executing swaps
/// @param minAmountOut Minimum acceptable amount of tokenOut (alpha-specified slippage protection)
/// @param data A set of data required to execute token swaps
struct UniversalTokenSwapperEthEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
    UniversalTokenSwapperEthData data;
}

struct Balances {
    uint256 tokenInBalanceBefore;
    uint256 tokenOutBalanceBefore;
    uint256 tokenInBalanceAfter;
    uint256 tokenOutBalanceAfter;
}

/// @title UniversalTokenSwapperEthFuse
/// @notice This contract is designed to execute every swap operation with ETH support and check the slippage on any DEX.
/// @dev Executes in PlasmaVault storage context via delegatecall.
///      CRITICAL: This contract MUST NOT contain storage variables.
///      Slippage is now configurable via substrate or defaults to DEFAULT_SLIPPAGE_WAD.
contract UniversalTokenSwapperEthFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when entering a swap operation
    event UniversalTokenSwapperEthFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    /// @notice Error thrown when asset is not in the substrate configuration
    error UniversalTokenSwapperEthFuseUnsupportedAsset(address asset);
    /// @notice Error thrown when USD-based slippage check fails
    error UniversalTokenSwapperEthFuseSlippageFail();
    /// @notice Error thrown when minAmountOut is not reached
    error UniversalTokenSwapperEthFuseMinAmountOutNotReached(uint256 expected, uint256 actual);
    /// @notice Error thrown when price oracle returns zero price
    error UniversalTokenSwapperEthFuseInvalidPrice(address asset);
    /// @notice Error thrown when price oracle middleware is not configured
    error UniversalTokenSwapperEthFuseInvalidPriceOracleMiddleware();
    /// @notice Error thrown when amountIn is zero
    error UniversalTokenSwapperEthFuseZeroAmount();
    /// @notice Error thrown when marketId is zero
    error UniversalTokenSwapperEthFuseInvalidMarketId();
    /// @notice Error thrown when WETH address is zero
    error UniversalTokenSwapperEthFuseInvalidWethAddress();

    /// @notice Fuse version identifier (set to deployment address)
    address public immutable VERSION;
    /// @notice Market identifier for this fuse instance
    uint256 public immutable MARKET_ID;
    /// @notice Address of the swap executor contract
    address payable public immutable EXECUTOR;

    /// @notice Default slippage in WAD (1e16 = 1%)
    uint256 public constant DEFAULT_SLIPPAGE_WAD = 1e16;

    uint256 private constant _ONE = 1e18;

    /// @notice Creates a new UniversalTokenSwapperEthFuse instance
    /// @param marketId_ Market identifier for this fuse
    /// @param wEth_ Address of the WETH contract (required for SwapExecutorEth)
    constructor(uint256 marketId_, address wEth_) {
        if (marketId_ == 0) {
            revert UniversalTokenSwapperEthFuseInvalidMarketId();
        }
        if (wEth_ == address(0)) {
            revert UniversalTokenSwapperEthFuseInvalidWethAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = payable(address(new SwapExecutorEth(wEth_)));
    }

    /// @notice Execute a swap operation
    /// @dev Called via delegatecall from PlasmaVault.execute()
    /// @param data_ Encoded UniversalTokenSwapperEthEnterData struct
    function enter(UniversalTokenSwapperEthEnterData calldata data_) external {
        if (data_.amountIn == 0) {
            revert UniversalTokenSwapperEthFuseZeroAmount();
        }

        _checkSubstrates(data_);

        address plasmaVault = address(this);

        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(data_.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(data_.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        ERC20(data_.tokenIn).safeTransfer(EXECUTOR, data_.amountIn);

        SwapExecutorEth(EXECUTOR).execute(
            SwapExecutorEthData({
                tokenIn: data_.tokenIn,
                tokenOut: data_.tokenOut,
                targets: data_.data.targets,
                callDatas: data_.data.callDatas,
                ethAmounts: data_.data.ethAmounts,
                tokensDustToCheck: data_.data.tokensDustToCheck
            })
        );

        balances.tokenInBalanceAfter = ERC20(data_.tokenIn).balanceOf(plasmaVault);
        balances.tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(plasmaVault);

        if (balances.tokenInBalanceAfter >= balances.tokenInBalanceBefore) {
            return;
        }

        uint256 tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert UniversalTokenSwapperEthFuseSlippageFail();
        }

        uint256 tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        // Check minAmountOut protection (if specified)
        if (data_.minAmountOut > 0 && tokenOutDelta < data_.minAmountOut) {
            revert UniversalTokenSwapperEthFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);

        emit UniversalTokenSwapperEthFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
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
            revert UniversalTokenSwapperEthFuseInvalidPriceOracleMiddleware();
        }

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        if (tokenInPrice == 0) {
            revert UniversalTokenSwapperEthFuseInvalidPrice(tokenIn_);
        }

        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);
        if (tokenOutPrice == 0) {
            revert UniversalTokenSwapperEthFuseInvalidPrice(tokenOut_);
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
            revert UniversalTokenSwapperEthFuseSlippageFail();
        }

        uint256 quotient = IporMath.division(amountUsdOutDelta * 1e18, amountUsdInDelta);

        uint256 slippageWad = _getSlippageLimit();
        uint256 slippageReverse = _ONE - slippageWad;

        if (quotient < slippageReverse) {
            revert UniversalTokenSwapperEthFuseSlippageFail();
        }
    }

    /// @notice Gets the slippage limit from substrate configuration or returns default
    /// @return slippageWad The slippage limit in WAD
    function _getSlippageLimit() internal view returns (uint256 slippageWad) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 length = substrates.length;

        for (uint256 i; i < length; ++i) {
            if (UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(substrates[i])) {
                return UniversalTokenSwapperSubstrateLib.decodeSlippage(substrates[i]);
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

    function _checkSubstrates(UniversalTokenSwapperEthEnterData calldata data_) private view {
        if (!_isTokenGranted(data_.tokenIn)) {
            revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!_isTokenGranted(data_.tokenOut)) {
            revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.tokenOut);
        }

        uint256 targetsLength = data_.data.targets.length;
        for (uint256 i; i < targetsLength; ++i) {
            if (!_isTargetGranted(data_.data.targets[i])) {
                revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.data.targets[i]);
            }
           
        }

        uint256 tokensDustToCheckLength = data_.data.tokensDustToCheck.length;
        for (uint256 i; i < tokensDustToCheckLength; ++i) {
            if (!_isTokenGranted(data_.data.tokensDustToCheck[i])) {
                revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.data.tokensDustToCheck[i]);
            }
        }
    }
}
