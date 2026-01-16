// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {INonfungiblePositionManagerRamses} from "./ext/INonfungiblePositionManagerRamses.sol";

/**
 * @title RamsesV2ModifyPositionFuse
 * @dev Contract for modifying liquidity positions in the Ramses V2 system.
 */
struct RamsesV2ModifyPositionFuseEnterData {
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

/// @notice Data for exiting RamsesV2ModifyPositionFuse.sol - decrease liquidity
struct RamsesV2ModifyPositionFuseExitData {
    /// @notice tokenId The ID of the token for which liquidity is being decreased
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

/// @dev Associated with fuse balance RamsesV2Balance.
contract RamsesV2ModifyPositionFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Event emitted when liquidity is increased in a position
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param liquidity The amount of liquidity added
    /// @param amount0 The amount of token0 added
    /// @param amount1 The amount of token1 added
    event RamsesV2ModifyPositionFuseEnter(
        address version,
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );

    /// @notice Event emitted when liquidity is decreased in a position
    /// @param version The address of the contract version
    /// @param tokenId The ID of the token
    /// @param amount0 The amount of token0 removed
    /// @param amount1 The amount of token1 removed
    event RamsesV2ModifyPositionFuseExit(address version, uint256 tokenId, uint256 amount0, uint256 amount1);

    error RamsesV2ModifyPositionFuseUnsupportedToken(address token0, address token1);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    /// @dev Manage NFTs representing liquidity positions
    address public immutable NONFUNGIBLE_POSITION_MANAGER;

    /**
     * @dev Constructor for the RamsesV2ModifyPositionFuse contract
     * @param marketId_ The ID of the market
     * @param nonfungiblePositionManager_ The address of the non-fungible position manager
     */
    constructor(uint256 marketId_, address nonfungiblePositionManager_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        NONFUNGIBLE_POSITION_MANAGER = nonfungiblePositionManager_;
    }

    /**
     * @notice Function to increase liquidity in a position
     * @param data_ The data containing the parameters for increasing liquidity
     * @return tokenId The ID of the token
     * @return liquidity The amount of liquidity added
     * @return amount0 The amount of token0 added
     * @return amount1 The amount of token1 added
     */
    function enter(
        RamsesV2ModifyPositionFuseEnterData memory data_
    ) public returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) {
        {
            if (
                !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token0) ||
                !PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.token1)
            ) {
                revert RamsesV2ModifyPositionFuseUnsupportedToken(data_.token0, data_.token1);
            }
        }

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount0Desired);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), data_.amount1Desired);

        (liquidity, amount0, amount1) = _increaseLiquidity(data_);

        IERC20(data_.token0).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);
        IERC20(data_.token1).forceApprove(address(NONFUNGIBLE_POSITION_MANAGER), 0);

        tokenId = data_.tokenId;

        emit RamsesV2ModifyPositionFuseEnter(VERSION, tokenId, liquidity, amount0, amount1);
    }

    function _increaseLiquidity(
        RamsesV2ModifyPositionFuseEnterData memory data_
    ) private returns (uint128 liquidity, uint256 amount0, uint256 amount1) {
        INonfungiblePositionManagerRamses.IncreaseLiquidityParams memory params = INonfungiblePositionManagerRamses
            .IncreaseLiquidityParams({
                tokenId: data_.tokenId,
                amount0Desired: data_.amount0Desired,
                amount1Desired: data_.amount1Desired,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        return INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).increaseLiquidity(params);
    }

    /**
     * @notice Function to decrease liquidity in a position
     * @param data_ The data containing the parameters for decreasing liquidity
     * @return tokenId The ID of the token
     * @return amount0 The amount of token0 removed
     * @return amount1 The amount of token1 removed
     */
    function exit(
        RamsesV2ModifyPositionFuseExitData memory data_
    ) public returns (uint256 tokenId, uint256 amount0, uint256 amount1) {
        (amount0, amount1) = _decreaseLiquidity(data_);

        tokenId = data_.tokenId;

        emit RamsesV2ModifyPositionFuseExit(VERSION, tokenId, amount0, amount1);
    }

    function _decreaseLiquidity(
        RamsesV2ModifyPositionFuseExitData memory data_
    ) private returns (uint256 amount0, uint256 amount1) {
        INonfungiblePositionManagerRamses.DecreaseLiquidityParams memory params = INonfungiblePositionManagerRamses
            .DecreaseLiquidityParams({
                tokenId: data_.tokenId,
                liquidity: data_.liquidity,
                amount0Min: data_.amount0Min,
                amount1Min: data_.amount1Min,
                deadline: data_.deadline
            });

        /// @dev This method doesn't transfer the liquidity to the caller
        return INonfungiblePositionManagerRamses(NONFUNGIBLE_POSITION_MANAGER).decreaseLiquidity(params);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        RamsesV2ModifyPositionFuseEnterData memory data_ = RamsesV2ModifyPositionFuseEnterData({
            token0: TypeConversionLib.toAddress(inputs[0]),
            token1: TypeConversionLib.toAddress(inputs[1]),
            tokenId: TypeConversionLib.toUint256(inputs[2]),
            amount0Desired: TypeConversionLib.toUint256(inputs[3]),
            amount1Desired: TypeConversionLib.toUint256(inputs[4]),
            amount0Min: TypeConversionLib.toUint256(inputs[5]),
            amount1Min: TypeConversionLib.toUint256(inputs[6]),
            deadline: TypeConversionLib.toUint256(inputs[7])
        });

        (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1) = enter(data_);

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(uint256(liquidity));
        outputs[2] = TypeConversionLib.toBytes32(amount0);
        outputs[3] = TypeConversionLib.toBytes32(amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads all parameters from transient storage and writes returned values to outputs
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        RamsesV2ModifyPositionFuseExitData memory data_ = RamsesV2ModifyPositionFuseExitData({
            tokenId: TypeConversionLib.toUint256(inputs[0]),
            liquidity: TypeConversionLib.toUint128(TypeConversionLib.toUint256(inputs[1])),
            amount0Min: TypeConversionLib.toUint256(inputs[2]),
            amount1Min: TypeConversionLib.toUint256(inputs[3]),
            deadline: TypeConversionLib.toUint256(inputs[4])
        });

        (uint256 tokenId, uint256 amount0, uint256 amount1) = exit(data_);

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(tokenId);
        outputs[1] = TypeConversionLib.toBytes32(amount0);
        outputs[2] = TypeConversionLib.toBytes32(amount1);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
