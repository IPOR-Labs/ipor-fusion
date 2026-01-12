// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

/// @notice Data structure used for collecting fees from Aerodrome Slipstream NFT positions
/// @dev This structure contains the list of NFT token IDs representing liquidity positions to collect fees from
/// @param tokenIds Array of NFT token IDs representing liquidity positions in Aerodrome Slipstream pools
struct AreodromeSlipstreamCollectFuseEnterData {
    uint256[] tokenIds;
}

/// @title AreodromeSlipstreamCollectFuse
/// @notice Fuse for collecting accumulated fees from Aerodrome Slipstream NFT positions
/// @dev This fuse allows users to collect fees that have accumulated in their NFT liquidity positions.
///      It iterates through multiple token IDs and collects fees from each position.
///      Supports both standard function calls and transient storage-based calls.
/// @author IPOR Labs
contract AreodromeSlipstreamCollectFuse is IFuseCommon {
    /// @notice Emitted when fees are collected from an NFT position
    /// @param version The address of the fuse contract version (VERSION immutable)
    /// @param tokenId The NFT token ID representing the liquidity position
    /// @param amount0 The amount of token0 collected as fees
    /// @param amount1 The amount of token1 collected as fees
    event AreodromeSlipstreamCollectFuseEnter(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    /// @notice Thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev Used for market-specific configuration and validation
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aerodrome Slipstream NonfungiblePositionManager contract
    /// @dev Manages NFT positions representing liquidity in Aerodrome Slipstream pools
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Constructor to initialize the fuse with market ID and position manager
    /// @param marketId_ The unique identifier for the market configuration
    /// @param nonfungiblePositionManager_ The address of the Aerodrome Slipstream NonfungiblePositionManager contract
    /// @dev Validates that nonfungiblePositionManager_ is not zero address.
    ///      Sets VERSION to the address of this contract instance.
    /// @custom:revert InvalidAddress When nonfungiblePositionManager_ is zero address
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /// @notice Collects fees from multiple NFT positions
    /// @dev Iterates through the provided token IDs and collects accumulated fees from each position.
    ///      Returns early with zero amounts if the tokenIds array is empty.
    ///      Emits an event for each position from which fees are collected.
    /// @param data_ Enter data containing array of token IDs representing liquidity positions
    /// @return totalAmount0 The total amount of token0 collected across all positions
    /// @return totalAmount1 The total amount of token1 collected across all positions
    function enter(
        AreodromeSlipstreamCollectFuseEnterData memory data_
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

            emit AreodromeSlipstreamCollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
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
            bytes32 tokenIdBytes32;

            for (uint256 i; i < len; ++i) {
                tokenIdBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
                tokenIds[i] = TypeConversionLib.toUint256(tokenIdBytes32);
            }

            AreodromeSlipstreamCollectFuseEnterData memory data = AreodromeSlipstreamCollectFuseEnterData({
                tokenIds: tokenIds
            });

            (totalAmount0, totalAmount1) = enter(data);
        }

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(totalAmount0);
        outputs[1] = TypeConversionLib.toBytes32(totalAmount1);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
