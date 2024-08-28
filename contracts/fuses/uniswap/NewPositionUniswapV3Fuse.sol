// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IFuse} from "../IFuse.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";

struct MintParams {
    address token0;
    address token1;
    uint24 fee;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
}

contract NewPositionUniswapV3Fuse is IFuse {
    using SafeERC20 for IERC20;

    event NewPositionUniswapV3FuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    error NewPositionUniswapV3FuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    function enter(bytes calldata data_) external override {
        enter(abi.decode(data_, (MintParams)));
    }

    function enter(MintParams memory data_) public {
        if (
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
            !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
        ) {
            revert NewPositionUniswapV3FuseUnsupportedToken(data_.token0, data_.token1);
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        // The values for tickLower and tickUpper may not work for all tick spacings.
        // Setting amount0Min and amount1Min to 0 is unsafe.
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: data_.token0,
            token1: data_.token1,
            fee: data_.fee,
            tickLower: data_.tickLower,
            tickUpper: data_.tickUpper,
            amount0Desired: data_.amount0Desired,
            amount1Desired: data_.amount1Desired,
            amount0Min: data_.amount0Min,
            amount1Min: data_.amount1Min,
            recipient: address(this),
            deadline: data_.deadline
        });

        // Note that the pool defined by token0/token1 and fee tier must already be created and initialized in order to mint
        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).mint(params);

        FuseStorageLib.getTokenIdUsedFuse().tokenIds.push(tokenId);

        emit NewPositionUniswapV3FuseEnter(VERSION, tokenId, liquidity, amount0, amount1);
    }

    function exit(bytes calldata data) external override {
        MintParams memory mintParams = abi.decode(data, (MintParams));
        // burn position
    }
}
