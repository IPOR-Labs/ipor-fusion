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

/// @notice Data structure used for executing a swap operation.
/// @param  targets - The array of addresses to which the call will be made.
/// @param  data - Data to be executed on the targets.
struct UniversalTokenSwapperEthData {
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

/// @notice Data structure used for entering a swap operation.
/// @param  tokenIn - The token that is to be transferred from the plasmaVault to the swapExecutor.
/// @param  tokenOut - The token that will be returned to the plasmaVault after the operation is completed.
/// @param  amountIn - The amount that needs to be transferred to the swapExecutor for executing swaps.
/// @param  data - A set of data required to execute token swaps
struct UniversalTokenSwapperEthEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    UniversalTokenSwapperEthData data;
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

/**
 * @title UniversalTokenSwapperEthFuse
 * @notice Universal fuse contract designed to execute swap operations on any DEX with ETH support and validate slippage
 * @dev This contract provides a generic interface for executing token swaps across multiple DEX protocols with support
 *      for ETH transfers. It validates asset permissions, executes swaps via an external executor, tracks balances,
 *      and enforces slippage protection using price oracle middleware. Supports transient storage for gas-efficient
 *      parameter passing. Includes support for ETH amounts and dust token checking.
 * @author IPOR Labs
 */
contract UniversalTokenSwapperEthFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    event UniversalTokenSwapperEthFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error UniversalTokenSwapperFuseUnsupportedAsset(address asset);
    error UniversalTokenSwapperFuseSlippageFail();
    error UniversalTokenSwapperFuseInvalidExecutorAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address payable public immutable EXECUTOR;
    /// @dev slippageReverse in WAD decimals, 1e18 - slippage;
    uint256 public immutable SLIPPAGE_REVERSE;

    constructor(uint256 marketId_, address executor_, uint256 slippageReverse_) {
        if (executor_ == address(0)) {
            revert UniversalTokenSwapperFuseInvalidExecutorAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = payable(executor_);
        if (slippageReverse_ > 1e18) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }
        SLIPPAGE_REVERSE = 1e18 - slippageReverse_;
    }

    /// @notice Enters the swap operation
    /// @param data_ The input data for the swap
    /// @return tokenIn The input token address
    /// @return tokenOut The output token address
    /// @return tokenInDelta The amount of input token consumed
    /// @return tokenOutDelta The amount of output token received
    function enter(
        UniversalTokenSwapperEthEnterData memory data_
    ) public returns (address tokenIn, address tokenOut, uint256 tokenInDelta, uint256 tokenOutDelta) {
        _checkSubstrates(data_);

        address plasmaVault = address(this);

        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(data_.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(data_.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        tokenIn = data_.tokenIn;
        tokenOut = data_.tokenOut;

        if (data_.amountIn == 0) {
            tokenInDelta = 0;
            tokenOutDelta = 0;
            _emitUniversalTokenSwapperFuseEnter(data_, tokenInDelta, tokenOutDelta);
            return (tokenIn, tokenOut, tokenInDelta, tokenOutDelta);
        }

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

        _checkSlippage(data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);

        _emitUniversalTokenSwapperFuseEnter(data_, tokenInDelta, tokenOutDelta);
    }

    /**
     * @notice Checks slippage tolerance for the swap operation
     * @dev Validates that the output token amount meets the minimum slippage requirement
     *      by comparing the USD value of output tokens against the USD value of input tokens.
     *      Uses price oracle middleware to get current token prices and converts amounts to USD.
     *      Reverts if the output/input ratio is below the SLIPPAGE_REVERSE threshold.
     * @param tokenIn_ The input token address
     * @param tokenOut_ The output token address
     * @param tokenInDelta_ The amount of input token consumed in the swap
     * @param tokenOutDelta_ The amount of output token received from the swap
     * @custom:reverts UniversalTokenSwapperFuseSlippageFail If slippage exceeds the allowed tolerance
     */
    function _checkSlippage(
        address tokenIn_,
        address tokenOut_,
        uint256 tokenInDelta_,
        uint256 tokenOutDelta_
    ) private view {
        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenIn_);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(tokenOut_);

        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta_ * tokenInPrice,
            IERC20Metadata(tokenIn_).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta_ * tokenOutPrice,
            IERC20Metadata(tokenOut_).decimals() + tokenOutPriceDecimals
        );

        uint256 quotient = IporMath.division(amountUsdOutDelta * 1e18, amountUsdInDelta);

        if (quotient < SLIPPAGE_REVERSE) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }
    }

    function _emitUniversalTokenSwapperFuseEnter(
        UniversalTokenSwapperEthEnterData memory data_,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    ) private {
        emit UniversalTokenSwapperEthFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads tokenIn, tokenOut, amountIn, and swap data arrays from transient storage.
    ///      Input 0: tokenIn (address)
    ///      Input 1: tokenOut (address)
    ///      Input 2: amountIn (uint256)
    ///      Input 3: targetsLength (uint256)
    ///      Inputs 4 to 4+targetsLength-1: targets (address[])
    ///      Input 4+targetsLength: callDatasLength (uint256)
    ///      For each callData (i from 0 to callDatasLength-1):
    ///        Input 4+targetsLength+1+i*2: callDataLength (uint256)
    ///        Inputs 4+targetsLength+1+i*2+1 to 4+targetsLength+1+i*2+1+ceil(callDataLength/32)-1: callData chunks (bytes32[])
    ///      Input after callDatas: ethAmountsLength (uint256)
    ///      Inputs after ethAmountsLength: ethAmounts (uint256[])
    ///      Input after ethAmounts: tokensDustToCheckLength (uint256)
    ///      Inputs after tokensDustToCheckLength: tokensDustToCheck (address[])
    ///      Writes returned tokenIn, tokenOut, tokenInDelta, and tokenOutDelta to transient storage outputs.
    function enterTransient() external {
        uint256 amountIn = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2));
        SwapExecutorEthData memory swapData;
        swapData.tokenIn = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 0));
        swapData.tokenOut = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 1));

        uint256 currentIndex = 3;
        (swapData.targets, currentIndex) = _readTargets(currentIndex);
        (swapData.callDatas, currentIndex) = _readCallDatas(currentIndex);
        (swapData.ethAmounts, currentIndex) = _readEthAmounts(currentIndex);
        (swapData.tokensDustToCheck, ) = _readTokensDustToCheck(currentIndex);

        UniversalTokenSwapperEthEnterData memory data = UniversalTokenSwapperEthEnterData({
            tokenIn: swapData.tokenIn,
            tokenOut: swapData.tokenOut,
            amountIn: amountIn,
            data: UniversalTokenSwapperEthData({
                targets: swapData.targets,
                callDatas: swapData.callDatas,
                ethAmounts: swapData.ethAmounts,
                tokensDustToCheck: swapData.tokensDustToCheck
            })
        });

        (address returnedTokenIn, address returnedTokenOut, uint256 tokenInDelta, uint256 tokenOutDelta) = enter(data);

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
     * @dev Reads the length of callDatas array from transient storage at currentIndex,
     *      then reads each bytes array sequentially. Each bytes array is stored as
     *      chunks of 32 bytes (bytes32) in transient storage. Used by enterTransient()
     *      to decode swap call data from transient storage.
     * @param currentIndex The current index in transient storage where callDatas length is stored
     * @return callDatas The array of bytes data (call data) read from transient storage
     * @return nextIndex The next index in transient storage after reading all call data arrays
     */
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

    /**
     * @notice Reads ETH amounts from transient storage inputs
     * @dev Reads the length of ethAmounts array from transient storage at currentIndex,
     *      then reads each ETH amount sequentially. Used by enterTransient() to decode
     *      ETH amounts to be sent with each swap call from transient storage.
     * @param currentIndex The current index in transient storage where ethAmounts length is stored
     * @return ethAmounts The array of ETH amounts (in wei) read from transient storage
     * @return nextIndex The next index in transient storage after reading all ETH amounts
     */
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

    /**
     * @notice Reads token addresses for dust checking from transient storage inputs
     * @dev Reads the length of tokensDustToCheck array from transient storage at currentIndex,
     *      then reads each token address sequentially. Used by enterTransient() to decode
     *      token addresses that should be checked for dust balances after swap execution.
     * @param currentIndex The current index in transient storage where tokensDustToCheck length is stored
     * @return tokensDustToCheck The array of token addresses to check for dust balances
     * @return nextIndex The next index in transient storage after reading all token addresses
     */
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

    /**
     * @notice Validates that all required substrates (assets) are granted for the swap operation
     * @dev Checks that tokenIn, tokenOut, all target addresses, and all tokensDustToCheck addresses
     *      are granted as substrates in the market configuration. Reverts if any asset is not granted.
     *      This ensures that only approved assets can be used in swap operations.
     * @param data_ The swap operation data containing all addresses to validate
     * @custom:reverts UniversalTokenSwapperFuseUnsupportedAsset If any asset is not granted as a substrate
     */
    function _checkSubstrates(UniversalTokenSwapperEthEnterData memory data_) private view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenIn)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.tokenOut)) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenOut);
        }

        uint256 targetsLength = data_.data.targets.length;
        for (uint256 i; i < targetsLength; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.data.targets[i])) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.targets[i]);
            }
        }

        uint256 tokensDustToCheckLength = data_.data.tokensDustToCheck.length;
        for (uint256 i; i < tokensDustToCheckLength; ++i) {
            if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.data.tokensDustToCheck[i])) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.tokensDustToCheck[i]);
            }
        }
    }
}
