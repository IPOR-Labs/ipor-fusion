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
/// @param  ethAmounts - ETH value to forward with each call
/// @param  tokensDustToCheck - Tokens that should be inspected for dust after execution
struct UniversalTokenSwapperWithVerificationData {
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
struct UniversalTokenSwapperWithVerificationEnterData {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    UniversalTokenSwapperWithVerificationData data;
}

/// @notice Data structure used for tracking token balances during swap operations.
/// @param  tokenInBalanceBefore - The balance of input token before the swap operation.
/// @param  tokenOutBalanceBefore - The balance of output token before the swap operation.
/// @param  tokenInBalanceAfter - The balance of input token after the swap operation.
/// @param  tokenOutBalanceAfter - The balance of output token after the swap operation.
struct Balances {
    uint256 tokenInBalanceBefore;
    uint256 tokenOutBalanceBefore;
    uint256 tokenInBalanceAfter;
    uint256 tokenOutBalanceAfter;
}

/// @notice Data structure used for substrate verification in token swaps.
/// @param  functionSelector - The function selector to be called on the target contract, For tokenIn and TokenOut and tokenDustToCheck this value is 0
/// @param  target - The address of the contract to be called.
struct UniversalTokenSwapperSubstrate {
    bytes4 functionSelector;
    address target;
}

/// @notice Data structure used for swap operation results.
/// @param  tokenIn - The input token address
/// @param  tokenOut - The output token address
/// @param  tokenInDelta - The amount of input token consumed
/// @param  tokenOutDelta - The amount of output token received
struct SwapResult {
    address tokenIn;
    address tokenOut;
    uint256 tokenInDelta;
    uint256 tokenOutDelta;
}

/// @title This contract is designed to execute every swap operation and check the slippage on any DEX.
/// @notice Allows executing swaps with verification of slippage and allowed substrates
/// @author IPOR Labs
contract UniversalTokenSwapperWithVerificationFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when a swap operation is entered
    /// @param version The address of the fuse version
    /// @param tokenIn The input token address
    /// @param tokenOut The output token address
    /// @param tokenInDelta The amount of input token consumed
    /// @param tokenOutDelta The amount of output token received
    event UniversalTokenSwapperWithVerificationFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error UniversalTokenSwapperFuseUnsupportedAsset(address asset);
    error UniversalTokenSwapperFuseSlippageFail();
    error UniversalTokenSwapperFuseInvalidExecutorAddress();

    /// @notice The address of the fuse version
    address public immutable VERSION;
    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;
    /// @notice The address of the swap executor contract
    address payable public immutable EXECUTOR;
    /// @dev slippageReverse in WAD decimals, 1e18 - slippage;
    /// @notice The reverse slippage tolerance (1e18 - slippage)
    uint256 public immutable SLIPPAGE_REVERSE;

    /// @notice Constructor to initialize the contract
    /// @param marketId_ The market ID
    /// @param executor_ The address of the swap executor
    /// @param slippageReverse_ The reverse slippage tolerance
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
    /// @return result The swap operation result containing tokenIn, tokenOut, tokenInDelta, and tokenOutDelta
    function enter(
        UniversalTokenSwapperWithVerificationEnterData calldata data_
    ) external returns (SwapResult memory result) {
        return
            _executeSwap(
                data_.amountIn,
                SwapExecutorEthData({
                    tokenIn: data_.tokenIn,
                    tokenOut: data_.tokenOut,
                    targets: data_.data.targets,
                    callDatas: data_.data.callDatas,
                    ethAmounts: data_.data.ethAmounts,
                    tokensDustToCheck: data_.data.tokensDustToCheck
                })
            );
    }

    /// @notice Internal function to execute the swap logic
    /// @param amountIn The amount of input token to swap
    /// @param swapData The swap execution data
    /// @return result The swap operation result containing tokenIn, tokenOut, tokenInDelta, and tokenOutDelta
    function _executeSwap(
        uint256 amountIn,
        SwapExecutorEthData memory swapData
    ) internal returns (SwapResult memory result) {
        _checkSubstrates(swapData);

        address plasmaVault = address(this);

        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(swapData.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(swapData.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        if (amountIn == 0) {
            result.tokenIn = swapData.tokenIn;
            result.tokenOut = swapData.tokenOut;
            result.tokenInDelta = 0;
            result.tokenOutDelta = 0;
            return result;
        }

        ERC20(swapData.tokenIn).safeTransfer(EXECUTOR, amountIn);

        SwapExecutorEth(EXECUTOR).execute(swapData);

        balances.tokenInBalanceAfter = ERC20(swapData.tokenIn).balanceOf(plasmaVault);
        balances.tokenOutBalanceAfter = ERC20(swapData.tokenOut).balanceOf(plasmaVault);

        if (balances.tokenInBalanceAfter >= balances.tokenInBalanceBefore) {
            result.tokenIn = swapData.tokenIn;
            result.tokenOut = swapData.tokenOut;
            result.tokenInDelta = 0;
            result.tokenOutDelta = 0;
            return result;
        }

        result.tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        result.tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(swapData.tokenIn);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(swapData.tokenOut);

        uint256 amountUsdInDelta = IporMath.convertToWad(
            result.tokenInDelta * tokenInPrice,
            IERC20Metadata(swapData.tokenIn).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            result.tokenOutDelta * tokenOutPrice,
            IERC20Metadata(swapData.tokenOut).decimals() + tokenOutPriceDecimals
        );

        uint256 quotient = IporMath.division(amountUsdOutDelta * 1e18, amountUsdInDelta);

        if (quotient < SLIPPAGE_REVERSE) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        result.tokenIn = swapData.tokenIn;
        result.tokenOut = swapData.tokenOut;

        _emitUniversalTokenSwapperFuseEnter(swapData, result.tokenInDelta, result.tokenOutDelta);
    }

    /// @notice Converts UniversalTokenSwapperSubstrate to bytes32
    /// @param substrate_ The substrate to convert
    /// @return The packed bytes32 representation
    function toBytes32(UniversalTokenSwapperSubstrate memory substrate_) public pure returns (bytes32) {
        return bytes32((uint256(uint32(substrate_.functionSelector)) << 224) | (uint256(uint160(substrate_.target))));
    }

    /// @notice Converts bytes32 back to UniversalTokenSwapperSubstrate
    /// @param data_ The bytes32 data to convert
    /// @return The unpacked UniversalTokenSwapperSubstrate
    function fromBytes32(bytes32 data_) public pure returns (UniversalTokenSwapperSubstrate memory) {
        return
            UniversalTokenSwapperSubstrate({
                functionSelector: bytes4(uint32(uint256(data_) >> 224)),
                target: address(uint160(uint256(data_)))
            });
    }

    /// @notice Emits the entry event
    /// @param data_ The swap data
    /// @param tokenInDelta The amount of input token consumed
    /// @param tokenOutDelta The amount of output token received
    function _emitUniversalTokenSwapperFuseEnter(
        SwapExecutorEthData memory data_,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    ) private {
        emit UniversalTokenSwapperWithVerificationFuseEnter(
            VERSION,
            data_.tokenIn,
            data_.tokenOut,
            tokenInDelta,
            tokenOutDelta
        );
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
        SwapResult memory result = _executeSwapTransient();

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenIn);
        outputs[1] = TypeConversionLib.toBytes32(result.tokenOut);
        outputs[2] = TypeConversionLib.toBytes32(result.tokenInDelta);
        outputs[3] = TypeConversionLib.toBytes32(result.tokenOutDelta);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Executes swap operation using transient storage for parameters
    /// @return result The swap operation result containing tokenIn, tokenOut, tokenInDelta, and tokenOutDelta
    function _executeSwapTransient() private returns (SwapResult memory result) {
        uint256 amountIn = TypeConversionLib.toUint256(TransientStorageLib.getInput(VERSION, 2));
        SwapExecutorEthData memory swapData;
        swapData.tokenIn = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 0));
        swapData.tokenOut = TypeConversionLib.toAddress(TransientStorageLib.getInput(VERSION, 1));

        uint256 currentIndex = 3;
        (swapData.targets, currentIndex) = _readTargets(currentIndex);
        (swapData.callDatas, currentIndex) = _readCallDatas(currentIndex);
        (swapData.ethAmounts, currentIndex) = _readEthAmounts(currentIndex);
        (swapData.tokensDustToCheck, currentIndex) = _readTokensDustToCheck(currentIndex);

        return _executeSwap(amountIn, swapData);
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

    /// @notice Checks if the swap parameters are allowed by the market substrates
    /// @param data_ The swap execution data
    function _checkSubstrates(SwapExecutorEthData memory data_) private view {
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: data_.tokenIn}))
            )
        ) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenIn);
        }
        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                toBytes32(UniversalTokenSwapperSubstrate({functionSelector: bytes4(0), target: data_.tokenOut}))
            )
        ) {
            revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokenOut);
        }
        uint256 targetsLength = data_.targets.length;
        for (uint256 i; i < targetsLength; ++i) {
            bytes memory callData = data_.callDatas[i];
            bytes4 functionSelector;
            if (callData.length >= 4) {
                assembly {
                    functionSelector := mload(add(callData, 0x20))
                }
                functionSelector = bytes4(functionSelector);
            }
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({functionSelector: functionSelector, target: data_.targets[i]})
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.targets[i]);
            }
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({functionSelector: functionSelector, target: data_.targets[i]})
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.targets[i]);
            }
        }
        uint256 tokensDustToCheckLength = data_.tokensDustToCheck.length;
        for (uint256 i; i < tokensDustToCheckLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({
                            functionSelector: bytes4(0),
                            target: data_.tokensDustToCheck[i]
                        })
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.tokensDustToCheck[i]);
            }
        }
    }
}
