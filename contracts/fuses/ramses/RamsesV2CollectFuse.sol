// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

struct RamsesV2CollectFuseEnterData {
    uint256[] tokenIds;
}

contract RamsesV2CollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event RamsesV2CollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

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

    function enter(RamsesV2CollectFuseEnterData calldata data_) public {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return;
        }

        INonfungiblePositionManagerRamses.CollectParams memory params;
        params.recipient = address(this);
        params.amount0Max = type(uint128).max;
        params.amount1Max = type(uint128).max;

        uint256 amount0;
        uint256 amount1;

        for (uint256 i; i < len; ++i) {
            params.tokenId = data_.tokenIds[i];

            (amount0, amount1) = INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).collect(params);

            emit RamsesV2CollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }
}