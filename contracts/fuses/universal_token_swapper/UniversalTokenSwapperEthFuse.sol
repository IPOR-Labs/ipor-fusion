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

struct Balances {
    uint256 tokenInBalanceBefore;
    uint256 tokenOutBalanceBefore;
    uint256 tokenInBalanceAfter;
    uint256 tokenOutBalanceAfter;
}

/// @title This contract is designed to execute every swap operation and check the slippage on any DEX.
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

    /// @notice Reads targets from transient storage
    /// @param currentIndex The current index in transient storage
    /// @return targets The array of target addresses
    /// @return nextIndex The next index in transient storage
    function _readTargets(uint256 currentIndex) private view returns (address[] memory targets, uint256 nextIndex) {
        uint256 len = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, currentIndex));
        nextIndex = currentIndex + 1;
        targets = new address[](len);
        for (uint256 i; i < len; ++i) {
            targets[i] = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, nextIndex));
            ++nextIndex;
        }
    }

    /// @notice Reads callDatas from transient storage
    /// @param currentIndex The current index in transient storage
    /// @return callDatas The array of call data bytes
    /// @return nextIndex The next index in transient storage
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

    /// @notice Reads ethAmounts from transient storage
    /// @param currentIndex The current index in transient storage
    /// @return ethAmounts The array of ETH amounts
    /// @return nextIndex The next index in transient storage
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

    /// @notice Reads tokensDustToCheck from transient storage
    /// @param currentIndex The current index in transient storage
    /// @return tokensDustToCheck The array of tokens to check for dust
    /// @return nextIndex The next index in transient storage
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
