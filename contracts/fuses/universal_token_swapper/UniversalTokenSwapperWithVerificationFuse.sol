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

/// @notice Data structure used for executing a swap operation.
/// @param  targets - The array of addresses to which the call will be made.
/// @param  data - Data to be executed on the targets.
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

/// @title This contract is designed to execute every swap operation and check the slippage on any DEX.
contract UniversalTokenSwapperWithVerificationFuse is IFuseCommon {
    using SafeERC20 for ERC20;

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

    function enter(UniversalTokenSwapperWithVerificationEnterData calldata data_) external {
        _checkSubstrates(data_);

        address plasmaVault = address(this);

        Balances memory balances = Balances({
            tokenInBalanceBefore: ERC20(data_.tokenIn).balanceOf(plasmaVault),
            tokenOutBalanceBefore: ERC20(data_.tokenOut).balanceOf(plasmaVault),
            tokenInBalanceAfter: 0,
            tokenOutBalanceAfter: 0
        });

        if (data_.amountIn == 0) {
            return;
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
            return;
        }

        uint256 tokenInDelta = balances.tokenInBalanceBefore - balances.tokenInBalanceAfter;

        if (balances.tokenOutBalanceAfter <= balances.tokenOutBalanceBefore) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        uint256 tokenOutDelta = balances.tokenOutBalanceAfter - balances.tokenOutBalanceBefore;

        address priceOracleMiddleware = PlasmaVaultLib.getPriceOracleMiddleware();

        (uint256 tokenInPrice, uint256 tokenInPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(data_.tokenIn);
        (uint256 tokenOutPrice, uint256 tokenOutPriceDecimals) = IPriceOracleMiddleware(priceOracleMiddleware)
            .getAssetPrice(data_.tokenOut);

        uint256 amountUsdInDelta = IporMath.convertToWad(
            tokenInDelta * tokenInPrice,
            IERC20Metadata(data_.tokenIn).decimals() + tokenInPriceDecimals
        );
        uint256 amountUsdOutDelta = IporMath.convertToWad(
            tokenOutDelta * tokenOutPrice,
            IERC20Metadata(data_.tokenOut).decimals() + tokenOutPriceDecimals
        );

        uint256 quotient = IporMath.division(amountUsdOutDelta * 1e18, amountUsdInDelta);

        if (quotient < SLIPPAGE_REVERSE) {
            revert UniversalTokenSwapperFuseSlippageFail();
        }

        _emitUniversalTokenSwapperFuseEnter(data_, tokenInDelta, tokenOutDelta);
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

    function _emitUniversalTokenSwapperFuseEnter(
        UniversalTokenSwapperWithVerificationEnterData calldata data_,
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

    function _checkSubstrates(UniversalTokenSwapperWithVerificationEnterData calldata data_) private view {
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
        uint256 targetsLength = data_.data.targets.length;
        for (uint256 i; i < targetsLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({
                            functionSelector: bytes4(data_.data.callDatas[i][0:4]),
                            target: data_.data.targets[i]
                        })
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.targets[i]);
            }
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({
                            functionSelector: bytes4(data_.data.callDatas[i][0:4]),
                            target: data_.data.targets[i]
                        })
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.targets[i]);
            }
        }
        uint256 tokensDustToCheckLength = data_.data.tokensDustToCheck.length;
        for (uint256 i; i < tokensDustToCheckLength; ++i) {
            if (
                !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                    MARKET_ID,
                    toBytes32(
                        UniversalTokenSwapperSubstrate({
                            functionSelector: bytes4(0),
                            target: data_.data.tokensDustToCheck[i]
                        })
                    )
                )
            ) {
                revert UniversalTokenSwapperFuseUnsupportedAsset(data_.data.tokensDustToCheck[i]);
            }
        }
    }
}
