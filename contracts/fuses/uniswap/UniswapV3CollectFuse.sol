// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data for collecting fees from Uniswap V3 positions
struct UniswapV3CollectFuseEnterData {
    /// @param tokenIds Array of NFT token IDs representing Uniswap V3 liquidity positions to collect fees from
    uint256[] tokenIds;
}

/// @title UniswapV3CollectFuse
/// @notice Fuse for collecting fees from Uniswap V3 liquidity positions
/// @dev This fuse allows the PlasmaVault to collect accumulated fees from Uniswap V3 positions.
///      It iterates through the provided token IDs and collects fees from each position.
contract UniswapV3CollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event UniswapV3CollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UnsupportedMethod();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /// @notice Collects fees from Uniswap V3 positions
    /// @param data_ The data containing array of token IDs to collect from
    /// @return totalAmount0 Total amount of token0 collected across all positions
    /// @return totalAmount1 Total amount of token1 collected across all positions
    function enter(
        UniswapV3CollectFuseEnterData memory data_
    ) public returns (uint256 totalAmount0, uint256 totalAmount1) {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return (0, 0);
        }

        INonfungiblePositionManager.CollectParams memory params;
        params.recipient = address(this);
        params.amount0Max = type(uint128).max;
        params.amount1Max = type(uint128).max;

        uint256 amount0;
        uint256 amount1;

        for (uint256 i; i < len; ++i) {
            params.tokenId = data_.tokenIds[i];

            (amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).collect(params);

            totalAmount0 += amount0;
            totalAmount1 += amount1;

            emit UniswapV3CollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        // inputs[0] contains the length of tokenIds array
        uint256 tokenIdsLength = TypeConversionLib.toUint256(inputs[0]);

        // Read tokenIds from inputs[1..n]
        uint256[] memory tokenIds = new uint256[](tokenIdsLength);
        for (uint256 i; i < tokenIdsLength; ++i) {
            tokenIds[i] = TypeConversionLib.toUint256(inputs[1 + i]);
        }

        // Call enter() and get returned values
        (uint256 totalAmount0, uint256 totalAmount1) = enter(UniswapV3CollectFuseEnterData(tokenIds));

        // Write outputs to transient storage
        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(totalAmount0);
        outputs[1] = TypeConversionLib.toBytes32(totalAmount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
