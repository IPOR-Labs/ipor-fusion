// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SwapExecutorEth, SwapExecutorEthData} from "./SwapExecutorEth.sol";

struct UniversalTokenSwapperEthDataNoSlippage {
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

struct UniversalTokenSwapperEthEnterDataNoSlippage {
    address tokenIn;
    address tokenOut;
    uint256 amountIn;
    UniversalTokenSwapperEthDataNoSlippage data;
}

contract UniversalTokenSwapperEthFuseNoSlippage is IFuseCommon {
    using SafeERC20 for ERC20;

    event UniversalTokenSwapperEthFuseEnter(
        address version,
        address tokenIn,
        address tokenOut,
        uint256 tokenInDelta,
        uint256 tokenOutDelta
    );

    error UniversalTokenSwapperFuseUnsupportedAsset(address asset);
    error UniversalTokenSwapperFuseInvalidExecutorAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address payable public immutable EXECUTOR;

    constructor(uint256 marketId_, address executor_) {
        if (executor_ == address(0)) {
            revert UniversalTokenSwapperFuseInvalidExecutorAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        EXECUTOR = payable(executor_);
    }

    function enter(UniversalTokenSwapperEthEnterDataNoSlippage calldata data_) external {
        _checkSubstrates(data_);

        if (data_.amountIn == 0) {
            return;
        }

        uint256 tokenOutBalanceBefore = ERC20(data_.tokenOut).balanceOf(address(this));

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

        uint256 tokenOutBalanceAfter = ERC20(data_.tokenOut).balanceOf(address(this));

        uint256 tokenInDelta = data_.amountIn;
        uint256 tokenOutDelta = tokenOutBalanceAfter > tokenOutBalanceBefore
            ? tokenOutBalanceAfter - tokenOutBalanceBefore
            : 0;

        emit UniversalTokenSwapperEthFuseEnter(VERSION, data_.tokenIn, data_.tokenOut, tokenInDelta, tokenOutDelta);
    }

    function _checkSubstrates(UniversalTokenSwapperEthEnterDataNoSlippage calldata data_) private view {
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
