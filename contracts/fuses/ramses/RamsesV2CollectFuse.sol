// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

struct RamsesV2CollectFuseEnterData {
    uint256[] tokenIds;
}
/**
 * @title RamsesV2CollectFuse
 * @dev Contract for collecting fees from Ramses V2 liquidity positions.
 */
contract RamsesV2CollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Event emitted when fees are collected from a position
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param amount0 The amount of token0 collected
    /// @param amount1 The amount of token1 collected
    event RamsesV2CollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /**
     * @dev Constructor for the RamsesV2CollectFuse contract
     * @param marketId_ The ID of the market
     * @param nonfungiblePositionManager_ The address of the non-fungible position manager
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Function to collect fees from multiple positions
     * @param data_ The data containing the token IDs of the positions
     */
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
