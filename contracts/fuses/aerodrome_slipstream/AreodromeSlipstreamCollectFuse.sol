// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct AreodromeSlipstreamCollectFuseEnterData {
    uint256[] tokenIds;
}

contract AreodromeSlipstreamCollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event AreodromeSlipstreamCollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error UnsupportedMethod();
    error InvalidAddress();

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    function enter(AreodromeSlipstreamCollectFuseEnterData calldata data_) public {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return;
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

            emit AreodromeSlipstreamCollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }
}
