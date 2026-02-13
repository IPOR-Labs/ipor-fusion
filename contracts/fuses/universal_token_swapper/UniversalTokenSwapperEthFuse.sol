// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {SwapExecutorEth, SwapExecutorEthData} from "./SwapExecutorEth.sol";
import {UniversalTokenSwapperSubstrateLib} from "./UniversalTokenSwapperSubstrateLib.sol";

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

/// @notice Struct containing validated substrate data (tokens, targets, slippage)
/// @param tokenInGranted Whether tokenIn is in the allowed substrates
/// @param tokenOutGranted Whether tokenOut is in the allowed substrates
/// @param slippageWad The slippage limit in WAD (or 0 if not found)
/// @param grantedTargets Bitmask of which targets are granted (bit i = targets[i] granted)
/// @param grantedDustTokens Bitmask of which dust tokens are granted (bit i = dustTokens[i] granted)
struct SubstrateValidationResultEth {
    bool tokenInGranted;
    bool tokenOutGranted;
    uint256 slippageWad;
    uint256 grantedTargets;
    uint256 grantedDustTokens;
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
    /// @notice Error thrown when slippage exceeds 100%
    error UniversalTokenSwapperEthFuseSlippageExceeds100Percent(uint256 slippageWad);
    /// @notice Error thrown when targets array is empty
    error UniversalTokenSwapperEthFuseEmptyTargets();
    /// @notice Error thrown when targets and data arrays have different lengths
    error UniversalTokenSwapperEthFuseArrayLengthMismatch();

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
    /// @custom:security Validates all tokens, targets and dust tokens against substrate configuration.
    ///                  Enforces minAmountOut and USD-based slippage protection.
    function enter(UniversalTokenSwapperEthEnterData memory data_) public {
        _enterInternal(data_);
    }

    /// @notice Internal implementation of enter logic
    /// @dev Shared by enter() and enterTransient() to avoid external call issues
    function _enterInternal(UniversalTokenSwapperEthEnterData memory data_) internal {
        if (data_.amountIn == 0) {
            revert UniversalTokenSwapperEthFuseZeroAmount();
        }

        // Single pass substrate validation - returns slippage for later use
        uint256 slippageWad = _checkSubstratesInternal(data_);

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

        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta, slippageWad);

        emit UniversalTokenSwapperEthFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    /// @notice Validates USD-based slippage protection
    /// @param tokenIn_ The input token address
    /// @param tokenOut_ The output token address
    /// @param tokenInDelta_ The amount of input token spent
    /// @param tokenOutDelta_ The amount of output token received
    /// @param slippageWad_ The slippage limit in WAD
    function _validateUsdSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_,
        uint256 slippageWad_
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

        uint256 slippageReverse = _ONE - slippageWad_;

        if (quotient < slippageReverse) {
            revert UniversalTokenSwapperEthFuseSlippageFail();
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads tokenIn, tokenOut, amountIn, minAmountOut, and swap data arrays from transient storage.
    ///      Input 0: tokenIn (address)
    ///      Input 1: tokenOut (address)
    ///      Input 2: amountIn (uint256)
    ///      Input 3: minAmountOut (uint256)
    ///      Input 4: targetsLength (uint256)
    ///      Inputs 5 to 5+targetsLength-1: targets (address[])
    ///      Input 5+targetsLength: callDatasLength (uint256)
    ///      For each callData (i from 0 to callDatasLength-1):
    ///        Input X: callDataLength (uint256)
    ///        Inputs X+1 to X+1+ceil(callDataLength/32)-1: callData chunks (bytes32[])
    ///      Input after callDatas: ethAmountsLength (uint256)
    ///      Inputs after ethAmountsLength: ethAmounts (uint256[])
    ///      Input after ethAmounts: tokensDustToCheckLength (uint256)
    ///      Inputs after tokensDustToCheckLength: tokensDustToCheck (address[])
    function enterTransient() external {
        address tokenIn = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 0));
        address tokenOut = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 1));
        uint256 amountIn = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2));
        uint256 minAmountOut = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 3));

        uint256 currentIndex = 4;
        address[] memory targets;
        bytes[] memory callDatas;
        uint256[] memory ethAmounts;
        address[] memory tokensDustToCheck;

        (targets, currentIndex) = _readTargets(currentIndex);
        (callDatas, currentIndex) = _readCallDatas(currentIndex);
        (ethAmounts, currentIndex) = _readEthAmounts(currentIndex);
        (tokensDustToCheck, ) = _readTokensDustToCheck(currentIndex);

        UniversalTokenSwapperEthEnterData memory data = UniversalTokenSwapperEthEnterData({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            data: UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            })
        });

        _enterInternal(data);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(tokenIn);
        outputs[1] = TypeConversionLib.toBytes32(tokenOut);
        outputs[2] = TypeConversionLib.toBytes32(amountIn);
        outputs[3] = TypeConversionLib.toBytes32(minAmountOut);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Reads target addresses from transient storage inputs
    /// @param currentIndex The current index in transient storage where targets length is stored
    /// @return targets The array of target addresses read from transient storage
    /// @return nextIndex The next index in transient storage after reading all targets
    function _readTargets(uint256 currentIndex) private view returns (address[] memory targets, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        targets = new address[](len);
        for (uint256 i; i < len; ++i) {
            targets[i] = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
        }
    }

    /// @notice Reads bytes arrays (call data) from transient storage inputs
    /// @param currentIndex The current index in transient storage where callDatas length is stored
    /// @return callDatas The array of bytes data (call data) read from transient storage
    /// @return nextIndex The next index in transient storage after reading all call data arrays
    function _readCallDatas(uint256 currentIndex) private view returns (bytes[] memory callDatas, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        callDatas = new bytes[](len);
        for (uint256 i; i < len; ++i) {
            uint256 dataLen = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
            bytes memory callData = new bytes(dataLen);
            uint256 chunksCount = (dataLen + 31) / 32;
            for (uint256 j; j < chunksCount; ++j) {
                bytes32 chunk = TransientStorageLib.getInput(VERSION, nextIndex);
                uint256 chunkStart = j * 32;
                assembly {
                    mstore(add(add(callData, 0x20), chunkStart), chunk)
                }
                ++nextIndex;
            }
            callDatas[i] = callData;
        }
    }

    /// @notice Reads ETH amounts from transient storage inputs
    /// @param currentIndex The current index in transient storage where ethAmounts length is stored
    /// @return ethAmounts The array of ETH amounts (in wei) read from transient storage
    /// @return nextIndex The next index in transient storage after reading all ETH amounts
    function _readEthAmounts(
        uint256 currentIndex
    ) private view returns (uint256[] memory ethAmounts, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        ethAmounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            ethAmounts[i] = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
        }
    }

    /// @notice Reads token addresses for dust checking from transient storage inputs
    /// @param currentIndex The current index in transient storage where tokensDustToCheck length is stored
    /// @return tokensDustToCheck The array of token addresses to check for dust balances
    /// @return nextIndex The next index in transient storage after reading all token addresses
    function _readTokensDustToCheck(
        uint256 currentIndex
    ) private view returns (address[] memory tokensDustToCheck, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        tokensDustToCheck = new address[](len);
        for (uint256 i; i < len; ++i) {
            tokensDustToCheck[i] = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
        }
    }

    /// @notice Validates all substrates in a single pass
    /// @dev Reads substrates only once and checks tokens, targets, dust tokens and slippage in one iteration
    /// @param tokenIn_ The input token address to validate
    /// @param tokenOut_ The output token address to validate
    /// @param targets_ The array of target addresses to validate
    /// @param dustTokens_ The array of dust token addresses to validate
    /// @return result Struct containing validation results for all checked items
    function _validateSubstrates(
        address tokenIn_,
        address tokenOut_,
        address[] memory targets_,
        address[] memory dustTokens_
    ) internal view returns (SubstrateValidationResultEth memory result) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 substratesLength = substrates.length;
        uint256 targetsLength = targets_.length;
        uint256 dustTokensLength = dustTokens_.length;

        for (uint256 i; i < substratesLength; ++i) {
            bytes32 substrate = substrates[i];

            if (UniversalTokenSwapperSubstrateLib.isTokenSubstrate(substrate)) {
                address token = UniversalTokenSwapperSubstrateLib.decodeToken(substrate);
                if (token == tokenIn_) {
                    result.tokenInGranted = true;
                }
                if (token == tokenOut_) {
                    result.tokenOutGranted = true;
                }
                // Check dust tokens
                for (uint256 j; j < dustTokensLength; ++j) {
                    if (dustTokens_[j] == token) {
                        result.grantedDustTokens |= (1 << j);
                    }
                }
            } else if (UniversalTokenSwapperSubstrateLib.isTargetSubstrate(substrate)) {
                address target = UniversalTokenSwapperSubstrateLib.decodeTarget(substrate);
                for (uint256 j; j < targetsLength; ++j) {
                    if (targets_[j] == target) {
                        result.grantedTargets |= (1 << j);
                    }
                }
            } else if (UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(substrate)) {
                result.slippageWad = UniversalTokenSwapperSubstrateLib.decodeSlippage(substrate);
                if (result.slippageWad > _ONE) {
                    revert UniversalTokenSwapperEthFuseSlippageExceeds100Percent(result.slippageWad);
                }
            }
        }

        if (result.slippageWad == 0) {
            result.slippageWad = DEFAULT_SLIPPAGE_WAD;
        }
    }

    /// @notice Validates all substrate requirements for the swap operation (internal version for memory data)
    /// @dev Checks tokenIn, tokenOut, all targets, and dust tokens against configured substrates in single pass
    /// @param data_ The swap data containing tokens and targets to validate
    /// @return slippageWad The slippage limit in WAD for use in USD slippage validation
    function _checkSubstratesInternal(UniversalTokenSwapperEthEnterData memory data_) private view returns (uint256 slippageWad) {
        uint256 targetsLength = data_.data.targets.length;
        if (targetsLength == 0) {
            revert UniversalTokenSwapperEthFuseEmptyTargets();
        }
        if (targetsLength != data_.data.callDatas.length) {
            revert UniversalTokenSwapperEthFuseArrayLengthMismatch();
        }
        if (targetsLength != data_.data.ethAmounts.length) {
            revert UniversalTokenSwapperEthFuseArrayLengthMismatch();
        }

        // Single pass substrate validation - reads substrates only once
        SubstrateValidationResultEth memory validation = _validateSubstrates(
            data_.tokenIn,
            data_.tokenOut,
            data_.data.targets,
            data_.data.tokensDustToCheck
        );

        if (!validation.tokenInGranted) {
            revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!validation.tokenOutGranted) {
            revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.tokenOut);
        }

        // Check all targets are granted using bitmask
        uint256 expectedTargetsMask = (1 << targetsLength) - 1;
        if (validation.grantedTargets != expectedTargetsMask) {
            // Find first non-granted target for error message
            for (uint256 i; i < targetsLength; ++i) {
                if ((validation.grantedTargets & (1 << i)) == 0) {
                    revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.data.targets[i]);
                }
            }
        }

        // Check all dust tokens are granted using bitmask
        uint256 dustTokensLength = data_.data.tokensDustToCheck.length;
        if (dustTokensLength > 0) {
            uint256 expectedDustMask = (1 << dustTokensLength) - 1;
            if (validation.grantedDustTokens != expectedDustMask) {
                // Find first non-granted dust token for error message
                for (uint256 i; i < dustTokensLength; ++i) {
                    if ((validation.grantedDustTokens & (1 << i)) == 0) {
                        revert UniversalTokenSwapperEthFuseUnsupportedAsset(data_.data.tokensDustToCheck[i]);
                    }
                }
            }
        }

        return validation.slippageWad;
    }
}
