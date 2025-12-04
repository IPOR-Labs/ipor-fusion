// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

/// @notice Data structure used for collecting fees from Velodrome Superchain Slipstream positions
/// @dev This structure contains an array of NFT token IDs representing liquidity positions to collect fees from
/// @param tokenIds Array of NFT token IDs representing the liquidity positions to collect fees from
struct VelodromeSuperchainSlipstreamCollectFuseEnterData {
    uint256[] tokenIds;
}

/// @notice Result structure returned after collecting fees from positions
/// @dev Contains the total amounts of token0 and token1 collected across all positions
/// @param totalAmount0 Total amount of token0 collected from all positions
/// @param totalAmount1 Total amount of token1 collected from all positions
struct VelodromeSuperchainSlipstreamCollectFuseEnterResult {
    uint256 totalAmount0;
    uint256 totalAmount1;
}

/// @title VelodromeSuperchainSlipstreamCollectFuse
/// @notice Fuse for collecting fees from Velodrome Superchain Slipstream NFT liquidity positions
/// @dev This fuse allows users to collect accumulated fees from their NFT liquidity positions.
///      It iterates through multiple token IDs and collects fees from each position.
///      Supports both standard function calls and transient storage-based calls.
/// @author IPOR Labs
contract VelodromeSuperchainSlipstreamCollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Emitted when fees are collected from a position
    /// @param version The version identifier of this fuse contract
    /// @param tokenId The NFT token ID representing the liquidity position
    /// @param amount0 The amount of token0 collected from this position
    /// @param amount1 The amount of token1 collected from this position
    event VelodromeSuperchainSlipstreamCollectFuseEnter(
        address version,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Thrown when an unsupported method is called
    error UnsupportedMethod();

    /// @notice Thrown when an invalid address (zero address) is provided
    error InvalidAddress();

    /// @notice The version identifier of this fuse contract
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    uint256 public immutable MARKET_ID;

    /// @notice The NonfungiblePositionManager contract address for managing NFT positions
    /// @dev Used to interact with Velodrome Superchain Slipstream NFT liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /// @notice Constructor to initialize the fuse with market ID and position manager address
    /// @param marketId_ The unique identifier for the market configuration
    /// @param nonfungiblePositionManager_ The address of the NonfungiblePositionManager contract
    /// @dev Sets VERSION to the address of this contract instance.
    ///      Validates that nonfungiblePositionManager_ is not the zero address.
    /// @custom:revert InvalidAddress When nonfungiblePositionManager_ is the zero address
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert InvalidAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /// @notice Collects fees from Velodrome Superchain Slipstream NFT liquidity positions
    /// @dev Iterates through the provided token IDs and collects accumulated fees from each position.
    ///      If the tokenIds array is empty, returns early with zero amounts.
    ///      For each position, collects fees up to the maximum available (type(uint128).max).
    ///      Accumulates total amounts of token0 and token1 collected across all positions.
    /// @param data_ Enter data containing array of NFT token IDs to collect fees from
    /// @return result Result structure containing total amounts of token0 and token1 collected
    function enter(
        VelodromeSuperchainSlipstreamCollectFuseEnterData memory data_
    ) public returns (VelodromeSuperchainSlipstreamCollectFuseEnterResult memory result) {
        uint256 len = data_.tokenIds.length;

        if (len == 0) {
            return result;
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

            result.totalAmount0 += amount0;
            result.totalAmount1 += amount1;

            emit VelodromeSuperchainSlipstreamCollectFuseEnter(VERSION, params.tokenId, amount0, amount1);
        }
    }

    /// @notice Collects fees from multiple NFT positions using transient storage for inputs
    /// @dev Reads tokenIds array from transient storage:
    ///      - Input index 0: length of the tokenIds array
    ///      - Input indices 1 to length: individual token IDs
    ///      Writes returned totalAmount0 and totalAmount1 to transient storage outputs:
    ///      - Output index 0: totalAmount0
    ///      - Output index 1: totalAmount1
    function enterTransient() external {
        bytes32 lengthBytes32 = TransientStorageLib.getInput(VERSION, 0);
        uint256 len = TypeConversionLib.toUint256(lengthBytes32);

        VelodromeSuperchainSlipstreamCollectFuseEnterResult memory result;

        if (len > 0) {
            uint256[] memory tokenIds = new uint256[](len);
            for (uint256 i; i < len; ++i) {
                bytes32 tokenIdBytes32 = TransientStorageLib.getInput(VERSION, i + 1);
                tokenIds[i] = TypeConversionLib.toUint256(tokenIdBytes32);
            }

            result = enter(VelodromeSuperchainSlipstreamCollectFuseEnterData({tokenIds: tokenIds}));
        }

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(result.totalAmount0);
        outputs[1] = TypeConversionLib.toBytes32(result.totalAmount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
