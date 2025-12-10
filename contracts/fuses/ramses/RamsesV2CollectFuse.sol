// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

/// @notice Data structure for entering - collecting fees from Ramses V2 positions
struct RamsesV2CollectFuseEnterData {
    /// @dev Array of token IDs representing liquidity positions to collect fees from
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
     * @return totalAmount0 The total amount of token0 collected
     * @return totalAmount1 The total amount of token1 collected
     */
    function enter(
        RamsesV2CollectFuseEnterData memory data_
    ) public returns (uint256 totalAmount0, uint256 totalAmount1) {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return (0, 0);
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

            totalAmount0 += amount0;
            totalAmount1 += amount1;

            emit RamsesV2CollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }

    /// @notice Collects fees from multiple NFT positions using transient storage for inputs
    /// @dev Reads tokenIds array from transient storage (first element is length, subsequent elements are tokenIds)
    /// @dev Writes returned totalAmount0 and totalAmount1 to transient storage outputs
    function enterTransient() external {
        bytes32 lengthBytes32 = TransientStorageLib.getInput(VERSION, 0);
        uint256 len = TypeConversionLib.toUint256(lengthBytes32);

        uint256 totalAmount0;
        uint256 totalAmount1;

        if (len == 0) {
            totalAmount0 = 0;
            totalAmount1 = 0;
        } else {
            uint256[] memory tokenIds = new uint256[](len);
            for (uint256 i; i < len; ++i) {
                bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
                tokenIds[i] = TypeConversionLib.toUint256(tokenIdBytes32);
            }

            RamsesV2CollectFuseEnterData memory data = RamsesV2CollectFuseEnterData({tokenIds: tokenIds});

            (totalAmount0, totalAmount1) = enter(data);
        }

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(totalAmount0);
        outputs[1] = TypeConversionLib.toBytes32(totalAmount1);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
