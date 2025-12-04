// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManager} from "./ext/INonfungiblePositionManager.sol";
import {VelodromeSuperchainSlipstreamSubstrateLib, VelodromeSuperchainSlipstreamSubstrateType, VelodromeSuperchainSlipstreamSubstrate} from "./VelodromeSuperchainSlipstreamSubstrateLib.sol";

/// @notice Data for entering a position in Velodrome Superchain Slipstream
struct VelodromeSuperchainSlipstreamModifyPositionFuseEnterData {
    /// @notice The address of the token0 for a specific pool
    address token0;
    /// @notice The address of the token1 for a specific pool
    address token1;
    /// @notice tokenId The ID of the token that represents the minted position
    uint256 tokenId;
    /// @notice The desired amount of token0 to be spent
    uint256 amount0Desired;
    /// @notice The desired amount of token1 to be spent
    uint256 amount1Desired;
    /// @notice The minimum amount of token0 to spend, which serves as a slippage check
    uint256 amount0Min;
    /// @notice The minimum amount of token1 to spend, which serves as a slippage check
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @notice Data for exiting (decreasing liquidity) a position in Velodrome Superchain Slipstream
struct VelodromeSuperchainSlipstreamModifyPositionFuseExitData {
    /// @notice The ID of the token for which liquidity is being decreased
    uint256 tokenId;
    /// @notice The amount by which liquidity will be decreased
    uint128 liquidity;
    /// @notice The minimum amount of token0 that should be accounted for the burned liquidity
    uint256 amount0Min;
    /// @notice The minimum amount of token1 that should be accounted for the burned liquidity
    uint256 amount1Min;
    /// @notice The time by which the transaction must be included to effect the change
    uint256 deadline;
}

/// @notice Result of entering (increasing liquidity) a position
struct VelodromeSuperchainSlipstreamModifyPositionFuseEnterResult {
    /// @notice The ID of the token
    uint256 tokenId;
    /// @notice The amount of liquidity added
    uint128 liquidity;
    /// @notice The amount of token0 added
    uint256 amount0;
    /// @notice The amount of token1 added
    uint256 amount1;
}

/// @notice Result of exiting (decreasing liquidity) a position
struct VelodromeSuperchainSlipstreamModifyPositionFuseExitResult {
    /// @notice The ID of the token
    uint256 tokenId;
    /// @notice The amount of token0 received
    uint256 amount0;
    /// @notice The amount of token1 received
    uint256 amount1;
}

/// @title Fuse for modifying Velodrome Superchain Slipstream positions
/// @notice Allows increasing and decreasing liquidity for existing positions
contract VelodromeSuperchainSlipstreamModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Emitted when liquidity is increased
    /// @param version The address of the fuse version
    /// @param tokenId The ID of the token
    /// @param liquidity The amount of liquidity added
    /// @param amount0 The amount of token0 added
    /// @param amount1 The amount of token1 added
    event VelodromeSuperchainSlipstreamModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Emitted when liquidity is decreased
    /// @param version The address of the fuse version
    /// @param tokenId The ID of the token
    /// @param amount0 The amount of token0 received
    /// @param amount1 The amount of token1 received
    event VelodromeSuperchainSlipstreamModifyPositionFuseExit(
        address version,
        uint256 tokenId,
        uint256 amount0,
        uint256 amount1
    );

    error VelodromeSuperchainSlipstreamModifyPositionFuseUnsupportedPool(address pool);
    error VelodromeSuperchainSlipstreamModifyPositionFuseInvalidAddress();
    error InvalidReturnData();

    /// @notice The address of this fuse contract
    address public immutable VERSION;
    /// @notice The market ID this fuse belongs to
    uint256 public immutable MARKET_ID;
    /// @notice Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;
    /// @notice The Velodrome Factory address
    address public immutable FACTORY;

    /**
     * @notice Initializes the VelodromeSuperchainSlipstreamModifyPositionFuse with market ID and position manager
     * @param marketId_ The market ID used to identify the market and validate pool substrates
     * @param nonfungiblePositionManager_ The address of the Velodrome Superchain Slipstream NonfungiblePositionManager (must not be address(0))
     * @dev Reverts if nonfungiblePositionManager_ is zero address. Retrieves factory address from position manager.
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        if (nonfungiblePositionManager_ == address(0)) {
            revert VelodromeSuperchainSlipstreamModifyPositionFuseInvalidAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
        FACTORY = INonfungiblePositionManager(nonfungiblePositionManager_).factory();
    }

    /// @notice Increases liquidity for an existing position
    /// @param data_ The data for increasing liquidity
    /// @return result The result containing tokenId, liquidity, amount0, and amount1
    function enter(
        VelodromeSuperchainSlipstreamModifyPositionFuseEnterData memory data_
    ) public returns (VelodromeSuperchainSlipstreamModifyPositionFuseEnterResult memory result) {
        (address token0, address token1, int24 tickSpacing) = _getPositionInfo(data_.tokenId);

        address pool = VelodromeSuperchainSlipstreamSubstrateLib.getPoolAddress(FACTORY, token0, token1, tickSpacing);

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Pool,
                        substrateAddress: pool
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamModifyPositionFuseUnsupportedPool(pool);
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        INonfungiblePositionManager.IncreaseLiquidityParams memory params = INonfungiblePositionManager
            .IncreaseLiquidityParams({
                tokenId: data_.tokenId,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (uint128 liquidity, uint256 amount0, uint256 amount1) = INonfungiblePositionManager(
            NONFUNGIBLE_POSITION_MANAGER
        ).increaseLiquidity(params);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        result.tokenId = data_.tokenId;
        result.liquidity = liquidity;
        result.amount0 = amount0;
        result.amount1 = amount1;

        emit VelodromeSuperchainSlipstreamModifyPositionFuseEnter(
            VERSION,
            result.tokenId,
            result.liquidity,
            result.amount0,
            result.amount1
        );
    }

    /// @notice Decreases liquidity for an existing position
    /// @param data_ The data for decreasing liquidity
    /// @return result The result containing tokenId, amount0, and amount1
    function exit(
        VelodromeSuperchainSlipstreamModifyPositionFuseExitData memory data_
    ) public returns (VelodromeSuperchainSlipstreamModifyPositionFuseExitResult memory result) {
        (address token0, address token1, int24 tickSpacing) = _getPositionInfo(data_.tokenId);

        address pool = VelodromeSuperchainSlipstreamSubstrateLib.getPoolAddress(FACTORY, token0, token1, tickSpacing);

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSlipstreamSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSlipstreamSubstrate({
                        substrateType: VelodromeSuperchainSlipstreamSubstrateType.Pool,
                        substrateAddress: pool
                    })
                )
            )
        ) {
            revert VelodromeSuperchainSlipstreamModifyPositionFuseUnsupportedPool(pool);
        }

        INonfungiblePositionManager.DecreaseLiquidityParams memory params = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        (uint256 amount0, uint256 amount1) = INonfungiblePositionManager(NONFUNGIBLE_POSITION_MANAGER)
            .decreaseLiquidity(params);

        result.tokenId = data_.tokenId;
        result.amount0 = amount0;
        result.amount1 = amount1;

        emit VelodromeSuperchainSlipstreamModifyPositionFuseExit(
            VERSION,
            result.tokenId,
            result.amount0,
            result.amount1
        );
    }

    /// @notice Gets the token0, token1, and tickSpacing for a given position token ID
    /// @param tokenId_ The ID of the token that represents the position
    /// @return token0 The address of the token0 for a specific pool
    /// @return token1 The address of the token1 for a specific pool
    /// @return tickSpacing The tick spacing associated with the pool
    function _getPositionInfo(
        uint256 tokenId_
    ) private view returns (address token0, address token1, int24 tickSpacing) {
        bytes memory callData = abi.encodeWithSelector(INonfungiblePositionManager.positions.selector, tokenId_);
        address positionManager = NONFUNGIBLE_POSITION_MANAGER;

        bool success;
        bytes memory returnData;

        assembly {
            let callDataLength := mload(callData)
            let callDataPointer := add(callData, 0x20)
            success := staticcall(gas(), positionManager, callDataPointer, callDataLength, 0, 0)

            let returnDataSize := returndatasize()
            returnData := mload(0x40)
            mstore(returnData, returnDataSize)
            mstore(0x40, add(returnData, add(returnDataSize, 0x20)))
            returndatacopy(add(returnData, 0x20), 0, returnDataSize)
        }

        if (!success || returnData.length < 160) revert InvalidReturnData();

        assembly {
            // token0 at index 2: 32 (length) + 32 * 2 = 96
            token0 := mload(add(returnData, 96))
            // token1 at index 3: 32 (length) + 32 * 3 = 128
            token1 := mload(add(returnData, 128))
            // tickSpacing at index 4: 32 (length) + 32 * 4 = 160
            tickSpacing := mload(add(returnData, 160))
        }
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainSlipstreamModifyPositionFuseEnterData
            memory data_ = VelodromeSuperchainSlipstreamModifyPositionFuseEnterData({
                token0: TypeConversionLib.toAddress(inputs[0]),
                token1: TypeConversionLib.toAddress(inputs[1]),
                tokenId: TypeConversionLib.toUint256(inputs[2]),
                amount0Desired: TypeConversionLib.toUint256(inputs[3]),
                amount1Desired: TypeConversionLib.toUint256(inputs[4]),
                amount0Min: TypeConversionLib.toUint256(inputs[5]),
                amount1Min: TypeConversionLib.toUint256(inputs[6]),
                deadline: TypeConversionLib.toUint256(inputs[7])
            });

        VelodromeSuperchainSlipstreamModifyPositionFuseEnterResult memory result = enter(data_);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(result.liquidity));
        outputs[2] = TypeConversionLib.toBytes32(result.amount0);
        outputs[3] = TypeConversionLib.toBytes32(result.amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainSlipstreamModifyPositionFuseExitData
            memory data_ = VelodromeSuperchainSlipstreamModifyPositionFuseExitData({
                tokenId: TypeConversionLib.toUint256(inputs[0]),
                liquidity: uint128(TypeConversionLib.toUint256(inputs[1])),
                amount0Min: TypeConversionLib.toUint256(inputs[2]),
                amount1Min: TypeConversionLib.toUint256(inputs[3]),
                deadline: TypeConversionLib.toUint256(inputs[4])
            });

        VelodromeSuperchainSlipstreamModifyPositionFuseExitResult memory result = exit(data_);

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(result.tokenId);
        outputs[1] = TypeConversionLib.toBytes32(result.amount0);
        outputs[2] = TypeConversionLib.toBytes32(result.amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
