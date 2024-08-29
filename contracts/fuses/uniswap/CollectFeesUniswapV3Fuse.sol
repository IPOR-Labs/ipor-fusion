// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuse} from "../IFuse.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct CollectFeesUniswapV3FuseEnterData {
    uint256[] tokenIds;
}

contract CollectFeesUniswapV3Fuse is IFuse {
    using SafeERC20 for IERC20;

    event CollectFeesUniswapV3FuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UnsupportedMethod();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    function enter(bytes calldata data_) external override {
        enter(abi.decode(data_, (CollectFeesUniswapV3FuseEnterData)));
    }

    function enter(CollectFeesUniswapV3FuseEnterData memory data_) public {
        if (data_.tokenIds.length == 0) {
            return;
        }

        INonfungiblePositionManager.CollectParams memory params;
        params.recipient = address(this);
        params.amount0Max = type(uint128).max;
        params.amount1Max = type(uint128).max;

        uint256 amount0;
        uint256 amount1;
        for (uint256 i = 0; i < data_.tokenIds.length; i++) {
            params.tokenId = data_.tokenIds[i];

            (amount0, amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER).collect(params);

            emit CollectFeesUniswapV3FuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }

    //solhint-disable-next-line
    function exit(bytes calldata data_) external {
        revert UnsupportedMethod();
    }
}
