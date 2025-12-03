// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";

struct VelodromeSuperchainSlipstreamCollectFuseEnterData {
    uint256[] tokenIds;
}

struct VelodromeSuperchainSlipstreamCollectFuseEnterResult {
    uint256 totalAmount0;
    uint256 totalAmount1;
}

contract VelodromeSuperchainSlipstreamCollectFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    event VelodromeSuperchainSlipstreamCollectFuseEnter(
        address version,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    );

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

    /// @notice Collects fees from Velodrome Superchain Slipstream positions
    /// @param data_ The data containing array of token IDs to collect from
    /// @return result The result containing total amounts collected
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
    /// @dev Reads tokenIds array from transient storage (first element is length, subsequent elements are tokenIds)
    /// @dev Writes returned totalAmount0 and totalAmount1 to transient storage outputs
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
