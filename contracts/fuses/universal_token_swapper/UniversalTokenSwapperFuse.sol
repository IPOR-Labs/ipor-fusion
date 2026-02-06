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
import {SwapExecutor, SwapExecutorData} from "./SwapExecutor.sol";
import {UniversalTokenSwapperSubstrateLib} from "./UniversalTokenSwapperSubstrateLib.sol";

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

/// @notice Data structure used to track token balances before and after swap operations
/// @param tokenInBalanceBefore The balance of input token before the swap operation
/// @param tokenOutBalanceBefore The balance of output token before the swap operation
/// @param tokenInBalanceAfter The balance of input token after the swap operation
/// @param tokenOutBalanceAfter The balance of output token after the swap operation
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
struct SubstrateValidationResult {
    bool tokenInGranted;
    bool tokenOutGranted;
    uint256 slippageWad;
    uint256 grantedTargets;
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

    /**
     * @notice Initializes the UniversalTokenSwapperFuse with market ID and executor address
     * @param marketId_ The market ID used to identify the market and validate asset permissions
     * @dev Reverts if marketId_ is zero
     */
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert UniversalTokenSwapperFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = address(new SwapExecutor());
    }

    /// @notice Enters the swap operation
    /// @param data_ The input data for the swap
    /// @return tokenIn The input token address
    /// @return tokenOut The output token address
    /// @return tokenInDelta The amount of input token consumed
    /// @return tokenOutDelta The amount of output token received
    function enter(
        UniversalTokenSwapperEnterData memory data_
    ) public returns (address tokenIn, address tokenOut, uint256 tokenInDelta, uint256 tokenOutDelta) {
        if (data_.amountIn == 0) {
            revert UniversalTokenSwapperFuseZeroAmount();
        }

        uint256 targetsLength = data_.data.targets.length;
        if (targetsLength == 0) {
            revert UniversalTokenSwapperFuseEmptyTargets();
        }
        if (targetsLength != data_.data.data.length) {
            revert UniversalTokenSwapperFuseArrayLengthMismatch();
        }

        SubstrateValidationResult memory validation = _validateSubstrates(
            data_.tokenIn,
            data_.tokenOut,
            data_.data.targets
        );
        if (!validation.tokenInGranted) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!validation.tokenOutGranted) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        // Check all targets are granted using bitmask
        uint256 expectedMask = (1 << targetsLength) - 1;
        if (validation.grantedTargets != expectedMask) {
            // Find first non-granted target for error message
            for (uint256 i; i < targetsLength; ++i) {
                if ((validation.grantedTargets & (1 << i)) == 0) {
                    revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.targets[i]);
                }
            }
        }

        tokenIn = data_.tokenIn;
        tokenOut = data_.tokenOut;

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
            tokenInDelta = 0;
            tokenOutDelta = 0;
            _emitUniversalTokenSwapperFuseEnter(data_, tokenInDelta, tokenOutDelta);
            return (tokenIn, tokenOut, tokenInDelta, tokenOutDelta);
        }

        tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        // Check minAmountOut protection (if specified)
        if (data_.minAmountOut > 0 && tokenOutDelta < data_.minAmountOut) {
            revert UniversalTokenSwapperFuseMinAmountOutNotReached(data_.minAmountOut, tokenOutDelta);
        }

        _validateUsdSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta, validation.slippageWad);

        _emitUniversalTokenSwapperFuseEnter(data_, tokenInDelta, tokenOutDelta);
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

        uint256 slippageReverse = _ONE - slippageWad_;

        if (quotient < slippageReverse) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }
    }

    /// @notice Validates all substrates in a single pass
    /// @dev Reads substrates only once and checks tokens, targets, and slippage in one iteration
    /// @param tokenIn_ The input token address to validate
    /// @param tokenOut_ The output token address to validate
    /// @param targets_ The array of target addresses to validate
    /// @return result Struct containing validation results for all checked items
    function _validateSubstrates(
        address tokenIn_,
        address tokenOut_,
        address[] memory targets_
    ) internal view returns (SubstrateValidationResult memory result) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        uint256 substratesLength = substrates.length;
        uint256 targetsLength = targets_.length;
        bytes32 substrate;
        address token;
        address target;
        
        for (uint256 i; i < substratesLength; ++i) {
            substrate = substrates[i];

            if (UniversalTokenSwapperSubstrateLib.isTokenSubstrate(substrate)) {
                token = UniversalTokenSwapperSubstrateLib.decodeToken(substrate);
                if (token == tokenIn_) {
                    result.tokenInGranted = true;
                }
                if (token == tokenOut_) {
                    result.tokenOutGranted = true;
                }
            } else if (UniversalTokenSwapperSubstrateLib.isTargetSubstrate(substrate)) {
                target = UniversalTokenSwapperSubstrateLib.decodeTarget(substrate);
                for (uint256 j; j < targetsLength; ++j) {
                    if (targets_[j] == target) {
                        result.grantedTargets |= (1 << j);
                    }
                }
            } else if (UniversalTokenSwapperSubstrateLib.isSlippageSubstrate(substrate)) {
                result.slippageWad = UniversalTokenSwapperSubstrateLib.decodeSlippage(substrate);
                if (result.slippageWad > _ONE) {
                    revert UniversalTokenSwapperFuseSlippageExceeds100Percent(result.slippageWad);
                }
            }
        }

        if (result.slippageWad == 0) {
            result.slippageWad = DEFAULT_SLIPPAGE_WAD;
        }
    }

    function _emitUniversalTokenSwapperFuseEnter(
        UniversalTokenSwapperEnterData memory data_,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    ) private {
        emit UniversalTokenSwapperFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads tokenIn, tokenOut, amountIn, targets array, and data arrays from transient storage.
    ///      Input 0: tokenIn (address)
    ///      Input 1: tokenOut (address)
    ///      Input 2: amountIn (uint256)
    ///      Input 3: targetsLength (uint256)
    ///      Inputs 4 to 3+targetsLength: targets (address[])
    ///      Input 3+targetsLength+1: dataLength (uint256)
    ///      For each data (i from 0 to dataLength-1):
    ///        Input 3+targetsLength+1+i*2+1: dataLength (uint256)
    ///        Inputs 3+targetsLength+1+i*2+2 to 3+targetsLength+1+i*2+1+ceil(dataLength/32): data chunks (bytes32[])
    ///      Writes returned tokenIn, tokenOut, tokenInDelta, and tokenOutDelta to transient storage outputs.
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address tokenIn = TypeConversionLib.toAddress(inputs[0]);
        address tokenOut = TypeConversionLib.toAddress(inputs[1]);
        uint256 amountIn = TypeConversionLib.toUint256(inputs[2]);

        uint256 currentIndex = 3;
        address[] memory targets;
        (targets, currentIndex) = _readTargets(currentIndex);
        bytes[] memory data;
        (data, currentIndex) = _readData(currentIndex);

        UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            minAmountOut: 0,
            data: UniversalTokenSwapperData({targets: targets, data: data})
        });

        (address returnedTokenIn, address returnedTokenOut, uint256 tokenInDelta, uint256 tokenOutDelta) = enter(
            enterData
        );

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedTokenIn);
        outputs[1] = TypeConversionLib.toBytes32(returnedTokenOut);
        outputs[2] = TypeConversionLib.toBytes32(tokenInDelta);
        outputs[3] = TypeConversionLib.toBytes32(tokenOutDelta);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Reads target addresses from transient storage inputs
     * @dev Reads the length of targets array from transient storage at currentIndex,
     *      then reads each target address sequentially. Used by enterTransient() to
     *      decode swap target addresses from transient storage.
     * @param currentIndex The current index in transient storage where targets length is stored
     * @return targets The array of target addresses read from transient storage
     * @return nextIndex The next index in transient storage after reading all targets
     */
    function _readTargets(uint256 currentIndex) private view returns (address[] memory targets, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        targets = new address[](len);
        for (uint256 i; i < len; ++i) {
            targets[i] = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
        }
    }

    /**
     * @notice Reads bytes arrays (call data) from transient storage inputs
     * @dev Reads the length of data array from transient storage at currentIndex,
     *      then reads each bytes array sequentially. Each bytes array is stored as
     *      chunks of 32 bytes (bytes32) in transient storage. Used by enterTransient()
     *      to decode swap call data from transient storage.
     * @param currentIndex The current index in transient storage where data length is stored
     * @return data The array of bytes data (call data) read from transient storage
     * @return nextIndex The next index in transient storage after reading all data arrays
     */
    function _readData(uint256 currentIndex) private view returns (bytes[] memory data, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        data = new bytes[](len);
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
            data[i] = callData;
        }
    }
}
