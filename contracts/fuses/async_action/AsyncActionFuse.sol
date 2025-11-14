// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {AsyncActionFuseLib, AllowedAmountToOutside, AllowedTargets} from "./AsyncActionFuseLib.sol";
import {AsyncExecutor, SwapExecutorEthData} from "./AsyncExecutor.sol";

/// @notice Input payload for executing an async action via the fuse
/// @param tokenOut Address of the asset expected to be transferred to the async executor
/// @param amountOut Amount of `tokenOut` to send to the async executor
/// @param targets Sequence of contracts that will be invoked by the async executor
/// @param callDatas Calldata for each target invocation
/// @param ethAmounts ETH value to forward with each call
/// @param tokensDustToCheck Tokens that should be inspected for dust after execution (currently unused)
struct AsyncActionFuseEnterData {
    address tokenOut;
    uint256 amountOut;
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

/// @title AsyncActionFuse
/// @notice Validates off-chain encoded asynchronous actions against market substrates before execution
/// @author IPOR Labs
contract AsyncActionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Emitted after a successful async action execution
    /// @param version Address of the fuse implementation that was executed
    /// @param tokenOut Asset that was transferred to the async executor
    /// @param amountOut Amount of `tokenOut` transferred to the async executor
    event AsyncActionFuseEnter(address indexed version, address indexed tokenOut, uint256 indexed amountOut);

    error AsyncActionFuseInvalidMarketId();
    error AsyncActionFuseInvalidWethAddress();
    error AsyncActionFuseInvalidArrayLength();
    error AsyncActionFuseTokenOutNotAllowed(address tokenOut, uint256 requestedAmount, uint256 maxAllowed);
    error AsyncActionFuseTargetNotAllowed(address target, bytes4 selector);
    error AsyncActionFuseCallDataTooShort(uint256 index);
    error AsyncActionFuseInvalidTokenOut();
    error AsyncActionFusePriceOracleNotConfigured();

    /// @notice Fuse implementation address
    address public immutable VERSION;
    /// @notice Market identifier used to resolve allowed substrates
    uint256 public immutable MARKET_ID;
    /// @notice Address of WETH used for wrapping ETH dust
    address public immutable W_ETH;

    /// @notice Initializes the fuse configuration
    /// @param marketId_ Identifier of the market whose substrates govern this fuse
    constructor(uint256 marketId_, address wEth_) {
        if (marketId_ == 0) {
            revert AsyncActionFuseInvalidMarketId();
        }
        if (wEth_ == address(0)) {
            revert AsyncActionFuseInvalidWethAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        W_ETH = wEth_;
    }

    /// @notice Validates provided payload and forwards execution instructions to the async executor
    /// @param data_ Complete execution payload encoded off-chain
    function enter(AsyncActionFuseEnterData calldata data_) external {
        if (data_.tokenOut == address(0)) {
            revert AsyncActionFuseInvalidTokenOut();
        }

        uint256 targetsLength_ = data_.targets.length;
        if (targetsLength_ != data_.callDatas.length || targetsLength_ != data_.ethAmounts.length) {
            revert AsyncActionFuseInvalidArrayLength();
        }

        bytes32[] memory substrates_ = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        (AllowedAmountToOutside[] memory allowedAmounts_, AllowedTargets[] memory allowedTargets_,) =
            AsyncActionFuseLib.decodeAsyncActionFuseSubstrates(substrates_);

        _validateTokenOutAndAmount(data_.tokenOut, data_.amountOut, allowedAmounts_);
        _validateTargets(data_.targets, data_.callDatas, allowedTargets_);

        address payable executor = payable(AsyncActionFuseLib.getAsyncExecutorAddress(W_ETH, address(this)));

        if (data_.amountOut > 0 && (AsyncExecutor(executor).balance() == 0)) {
            IERC20(data_.tokenOut).safeTransfer(executor, data_.amountOut);
        }

        address priceOracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracle == address(0)) {
            revert AsyncActionFusePriceOracleNotConfigured();
        }


        AsyncExecutor(executor).execute(
            SwapExecutorEthData({
                tokenIn: data_.tokenOut,
                targets: data_.targets,
                callDatas: data_.callDatas,
                ethAmounts: data_.ethAmounts,
                priceOracle: priceOracle
            })
        );

        emit AsyncActionFuseEnter(VERSION, data_.tokenOut, data_.amountOut);
    }

    /// @notice Ensures token and amount requested are within substrate defined boundaries
    /// @param tokenOut_ Asset requested for transfer
    /// @param amountOut_ Amount requested for transfer
    /// @param allowedAmounts_ Substrate encoded limits defined for the market
    function _validateTokenOutAndAmount(
        address tokenOut_,
        uint256 amountOut_,
        AllowedAmountToOutside[] memory allowedAmounts_
    ) private pure {
        uint256 allowedAmount;
        bool found;

        uint256 allowedAmountsLength = allowedAmounts_.length;
        for (uint256 i; i < allowedAmountsLength; ++i) {
            if (allowedAmounts_[i].asset == tokenOut_) {
                found = true;
                allowedAmount = allowedAmounts_[i].amount;
                break;
            }
        }

        if (!found) {
            revert AsyncActionFuseTokenOutNotAllowed(tokenOut_, amountOut_, 0);
        }

        if (amountOut_ > allowedAmount) {
            revert AsyncActionFuseTokenOutNotAllowed(tokenOut_, amountOut_, allowedAmount);
        }
    }

    /// @notice Verifies that each target/selector pair is permitted for the market
    /// @param targets_ Array of target contract addresses
    /// @param callDatas_ Array of ABI-encoded calls
    /// @param allowedTargets_ Substrate encoded target permissions defined for the market
    function _validateTargets(
        address[] calldata targets_,
        bytes[] calldata callDatas_,
        AllowedTargets[] memory allowedTargets_
    ) private pure {
        uint256 targetsLength_ = targets_.length;
        uint256 allowedTargetsLength_ = allowedTargets_.length;

        for (uint256 i_; i_ < targetsLength_; ++i_) {
            bytes calldata callData_ = callDatas_[i_];
            if (callData_.length < 4) {
                revert AsyncActionFuseCallDataTooShort(i_);
            }

            bytes4 selector_ = bytes4(callData_[:4]);
            address target_ = targets_[i_];
            bool allowed_;

            for (uint256 j_; j_ < allowedTargetsLength_; ++j_) {
                AllowedTargets memory allowedTarget_ = allowedTargets_[j_];
                if (allowedTarget_.target == target_ && allowedTarget_.selector == selector_) {
                    allowed_ = true;
                    break;
                }
            }

            if (!allowed_) {
                revert AsyncActionFuseTargetNotAllowed(target_, selector_);
            }
        }
    }
}