// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {AsyncActionFuseLib, AllowedAmountToOutside, AllowedTargets, AllowedSlippage} from "./AsyncActionFuseLib.sol";
import {AsyncExecutor, SwapExecutorEthData} from "./AsyncExecutor.sol";

/// @notice Input payload for executing an async action via the fuse
/// @param tokenOut Address of the asset expected to be transferred to the async executor
/// @param amountOut Amount of `tokenOut` to send to the async executor
/// @param targets Sequence of contract addresses that will be invoked by the async executor
/// @param callDatas Calldata for each target invocation
/// @param ethAmounts ETH value to forward with each call
/// @param tokensDustToCheck Tokens that should be inspected for dust after execution (currently unused in this implementation)
struct AsyncActionFuseEnterData {
    address tokenOut;
    uint256 amountOut;
    address[] targets;
    bytes[] callDatas;
    uint256[] ethAmounts;
    address[] tokensDustToCheck;
}

/// @notice Input payload for fetching assets from async executor via the fuse
/// @param assets List of ERC20 asset addresses to fetch and transfer from executor
struct AsyncActionFuseExitData {
    address[] assets;
    bytes[] fetchCallDatas;
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

    /// @notice Emitted after a successful asset fetch from async executor
    /// @param version Address of the fuse implementation that executed the fetch
    /// @param assets Array of asset addresses that were fetched
    event AsyncActionFuseExit(address indexed version, address[] assets);

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AsyncActionFuseInvalidMarketId
    error AsyncActionFuseInvalidMarketId();

    /// @notice Thrown when WETH address is zero
    /// @custom:error AsyncActionFuseInvalidWethAddress
    error AsyncActionFuseInvalidWethAddress();

    /// @notice Thrown when arrays have mismatched lengths
    /// @custom:error AsyncActionFuseInvalidArrayLength
    error AsyncActionFuseInvalidArrayLength();

    /// @notice Thrown when token is not allowed or requested amount exceeds allowed limit
    /// @param tokenOut The token address that was not allowed or exceeded limit
    /// @param requestedAmount The amount that was requested
    /// @param maxAllowed The maximum allowed amount (0 if token not found)
    /// @custom:error AsyncActionFuseTokenOutNotAllowed
    error AsyncActionFuseTokenOutNotAllowed(address tokenOut, uint256 requestedAmount, uint256 maxAllowed);

    /// @notice Thrown when target/selector pair is not in the allowed list
    /// @param target The target contract address
    /// @param selector The function selector
    /// @custom:error AsyncActionFuseTargetNotAllowed
    error AsyncActionFuseTargetNotAllowed(address target, bytes4 selector);

    /// @notice Thrown when callData is shorter than 4 bytes (minimum for function selector)
    /// @param index The index of the callData in the array that is too short
    /// @custom:error AsyncActionFuseCallDataTooShort
    error AsyncActionFuseCallDataTooShort(uint256 index);

    /// @notice Thrown when tokenOut address is zero
    /// @custom:error AsyncActionFuseInvalidTokenOut
    error AsyncActionFuseInvalidTokenOut();

    /// @notice Thrown when price oracle middleware is not configured in the Plasma Vault
    /// @custom:error AsyncActionFusePriceOracleNotConfigured
    error AsyncActionFusePriceOracleNotConfigured();

    /// @notice Thrown when executor balance is not zero
    /// @custom:error AsyncActionFuseBalanceNotZero
    error AsyncActionFuseBalanceNotZero();

    /// @notice Thrown when executor address is zero
    /// @custom:error AsyncActionFuseInvalidExecutorAddress
    error AsyncActionFuseInvalidExecutorAddress();

    /// @notice Fuse implementation address
    address public immutable VERSION;
    /// @notice Market identifier used to resolve allowed substrates
    uint256 public immutable MARKET_ID;
    /// @notice Address of WETH used for wrapping ETH dust
    address public immutable W_ETH;

    /// @notice Initializes the fuse configuration
    /// @param marketId_ Identifier of the market whose substrates govern this fuse
    /// @param wEth_ Address of the WETH token contract (must not be address(0))
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
    /// @dev Performs validation of token, amount, and target/selector pairs against market substrates.
    ///      Validates that tokenOut is allowed and amountOut does not exceed allowed limits.
    ///      Validates that each target/selector pair is in the allowed list.
    ///      If executor balance is zero and amountOut > 0, transfers tokens to executor before execution.
    ///      Reverts if executor has non-zero balance when amountOut > 0.
    ///      Requires price oracle to be configured in the Plasma Vault.
    function enter(AsyncActionFuseEnterData calldata data_) external {
        if (data_.tokenOut == address(0)) {
            revert AsyncActionFuseInvalidTokenOut();
        }

        uint256 targetsLength = data_.targets.length;
        if (targetsLength != data_.callDatas.length || targetsLength != data_.ethAmounts.length) {
            revert AsyncActionFuseInvalidArrayLength();
        }

        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        (AllowedAmountToOutside[] memory allowedAmounts, AllowedTargets[] memory allowedTargets, ) = AsyncActionFuseLib
            .decodeAsyncActionFuseSubstrates(substrates);

        _validateTokenOutAndAmount(data_.tokenOut, data_.amountOut, allowedAmounts);
        _validateTargets(data_.targets, data_.callDatas, allowedTargets);

        address payable executor = payable(AsyncActionFuseLib.getAsyncExecutorAddress(W_ETH, address(this)));

        // Transfer tokens to executor only if executor has zero balance and amountOut > 0
        // Revert if executor has non-zero balance when amountOut > 0 to prevent state conflicts
        if (data_.amountOut > 0 && (AsyncExecutor(executor).balance() == 0)) {
            IERC20(data_.tokenOut).safeTransfer(executor, data_.amountOut);
        } else if (data_.amountOut > 0 && (AsyncExecutor(executor).balance() > 0)) {
            revert AsyncActionFuseBalanceNotZero();
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

    /// @notice Fetches assets from async executor back to Plasma Vault
    /// @param data_ Complete exit payload containing assets to fetch
    /// @dev Fetches specified assets from the async executor and transfers them to the Plasma Vault.
    ///      Slippage tolerance is read from market substrates.
    ///      Requires executor address to be set and price oracle to be configured in the Plasma Vault.
    ///      Returns early if assets array is empty.
    function exit(AsyncActionFuseExitData calldata data_) external {
        uint256 assetsLength = data_.assets.length;
        if (assetsLength == 0) {
            return;
        }

        // Get slippage from substrates
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(MARKET_ID);
        (, AllowedTargets[] memory allowedTargets, AllowedSlippage memory allowedSlippage) = AsyncActionFuseLib
            .decodeAsyncActionFuseSubstrates(substrates);

        // Get executor address
        address payable executor = payable(AsyncActionFuseLib.getAsyncExecutor());
        if (executor == address(0)) {
            revert AsyncActionFuseInvalidExecutorAddress();
        }

        // Get price oracle
        address priceOracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracle == address(0)) {
            revert AsyncActionFusePriceOracleNotConfigured();
        }

        _validateTargets(data_.assets, data_.fetchCallDatas, allowedTargets);

        // Call fetchAssets on executor
        AsyncExecutor(executor).fetchAssets(data_.assets, priceOracle, allowedSlippage.slippage);

        emit AsyncActionFuseExit(VERSION, data_.assets);
    }

    /// @notice Ensures token and amount requested are within substrate-defined boundaries
    /// @param tokenOut_ Asset requested for transfer
    /// @param amountOut_ Amount requested for transfer
    /// @param allowedAmounts_ Substrate-encoded limits defined for the market
    /// @dev Searches allowedAmounts_ array for matching token address and validates requested amount.
    ///      Reverts if token is not found in allowed list or if requested amount exceeds allowed limit.
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
    /// @param allowedTargets_ Substrate-encoded target permissions defined for the market
    /// @dev Validates that each target address and function selector combination is present in allowedTargets_.
    ///      Extracts selector from first 4 bytes of each callData.
    ///      Reverts if callData is too short (< 4 bytes) or if any target/selector pair is not found in the allowed list.
    function _validateTargets(
        address[] calldata targets_,
        bytes[] calldata callDatas_,
        AllowedTargets[] memory allowedTargets_
    ) private pure {
        uint256 targetsLength = targets_.length;
        uint256 allowedTargetsLength = allowedTargets_.length;
        bytes calldata callData;

        for (uint256 i; i < targetsLength; ++i) {
            callData = callDatas_[i];
            if (callData.length < 4) {
                revert AsyncActionFuseCallDataTooShort(i);
            }

            // Extract function selector from first 4 bytes of callData
            bytes4 selector = bytes4(callData[:4]);
            address target = targets_[i];
            bool allowed;

            AllowedTargets memory allowedTarget;

            // Check if target/selector pair exists in the allowed list
            for (uint256 j; j < allowedTargetsLength; ++j) {
                allowedTarget = allowedTargets_[j];
                if (allowedTarget.target == target && allowedTarget.selector == selector) {
                    allowed = true;
                    break;
                }
            }

            if (!allowed) {
                revert AsyncActionFuseTargetNotAllowed(target, selector);
            }
        }
    }
}
