// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

struct CurveStableswapNGSingleSideSupplyFuseEnterData {
    /// @notice Curve pool contract to enter
    ICurveStableswapNG curveStableswapNG;
    /// @notice asset to deposit
    address asset;
    /// @notice Amount of the asset to deposit
    uint256 assetAmount;
    /// @notice Minimum amount of LP tokens to mint from the deposit
    uint256 minLpTokenAmountReceived;
}

struct CurveStableswapNGSingleSideSupplyFuseExitData {
    /// @notice Curve pool contract to exit
    ICurveStableswapNG curveStableswapNG;
    /// @notice Amount of LP tokens to burn
    uint256 lpTokenAmount;
    /// @notice Address of the asset to withdraw
    address asset;
    /// @notice Minimum amount of the coin to receive
    uint256 minCoinAmountReceived;
}

/// @title Fuse for Curve Stableswap NG protocol responsible for supplying and withdrawing assets from the Curve Stableswap NG protocol based on preconfigured market substrates
contract CurveStableswapNGSingleSideSupplyFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event CurveSupplyStableswapNGSingleSideSupplyFuseEnter(
        address version,
        address curvePool,
        address asset,
        uint256 assetAmount,
        uint256 lpTokenAmountReceived
    );

    event CurveSupplyStableswapNGSingleSideSupplyFuseExit(
        address version,
        address curvePool,
        uint256 lpTokenAmount,
        address asset,
        uint256 coinAmountReceived
    );

    error CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address poolAddress);
    error CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address asset);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(
        CurveStableswapNGSingleSideSupplyFuseEnterData memory data_
    ) public returns (address curveStableswapNG, uint256 lpTokenAmountReceived) {
        ICurveStableswapNG curvePool = ICurveStableswapNG(data_.curveStableswapNG);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(curvePool))) {
            /// @notice substrateAsAsset here refers to the Curve pool LP token, not the underlying asset of the Plasma Vault
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address(curvePool));
        }

        if (data_.assetAmount == 0) {
            return (address(data_.curveStableswapNG), 0);
        }

        uint256 nCoins = curvePool.N_COINS();
        uint256[] memory coinsAmounts = new uint256[](nCoins);
        bool supportedPoolAsset = false;

        for (uint256 i; i < nCoins; ++i) {
            if (curvePool.coins(i) == data_.asset) {
                supportedPoolAsset = true;
                coinsAmounts[i] = data_.assetAmount;
                ERC20(data_.asset).forceApprove(address(curvePool), data_.assetAmount);
            }
        }

        if (!supportedPoolAsset) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(data_.asset);
        }

        lpTokenAmountReceived = curvePool.add_liquidity(coinsAmounts, data_.minLpTokenAmountReceived, address(this));

        emit CurveSupplyStableswapNGSingleSideSupplyFuseEnter(
            VERSION,
            address(curvePool),
            data_.asset,
            data_.assetAmount,
            lpTokenAmountReceived
        );

        return (address(curvePool), lpTokenAmountReceived);
    }

    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address curveStableswapNG = TypeConversionLib.toAddress(inputs[0]);
        address asset = TypeConversionLib.toAddress(inputs[1]);
        uint256 assetAmount = TypeConversionLib.toUint256(inputs[2]);
        uint256 minLpTokenAmountReceived = TypeConversionLib.toUint256(inputs[3]);

        (address curveStableswapNGUsed, uint256 lpTokenAmountReceived) = enter(
            CurveStableswapNGSingleSideSupplyFuseEnterData({
                curveStableswapNG: ICurveStableswapNG(curveStableswapNG),
                asset: asset,
                assetAmount: assetAmount,
                minLpTokenAmountReceived: minLpTokenAmountReceived
            })
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(curveStableswapNGUsed);
        outputs[1] = TypeConversionLib.toBytes32(lpTokenAmountReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev Reverts propagate: this fuse has no `instantWithdraw()`, so unlike the sibling supply fuses'
    /// permissionless withdraw path there is no case here where a failed exit should be swallowed instead of
    /// stopping the ALPHA batch. The requested `lpTokenAmount` is clamped to the vault's current LP balance
    /// (part of it may be staked elsewhere, e.g. in a gauge) and the emitted/returned amount always reflects the
    /// clamped amount that was actually burned, never the raw request.
    function exit(
        CurveStableswapNGSingleSideSupplyFuseExitData memory data_
    ) public returns (address curveStableswapNG, uint256 coinAmountReceived) {
        ICurveStableswapNG curvePool = ICurveStableswapNG(data_.curveStableswapNG);

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(curvePool))) {
            /// @notice substrateAsAsset here refers to the Curve pool LP token, not the underlying asset of the Plasma Vault
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address(curvePool));
        }

        if (data_.lpTokenAmount == 0) {
            return (address(data_.curveStableswapNG), 0);
        }

        uint256 nCoins = curvePool.N_COINS();
        bool supportedPoolAsset = false;
        int128 index;

        for (uint256 i; i < nCoins; ++i) {
            if (curvePool.coins(i) == data_.asset) {
                index = int128(int256(i));
                supportedPoolAsset = true;
                break;
            }
        }

        if (!supportedPoolAsset) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(data_.asset);
        }

        uint256 vaultLpBalance = ERC20(address(curvePool)).balanceOf(address(this));
        uint256 finalLpTokenAmount = data_.lpTokenAmount > vaultLpBalance ? vaultLpBalance : data_.lpTokenAmount;

        if (finalLpTokenAmount == 0) {
            return (address(curvePool), 0);
        }

        coinAmountReceived = curvePool.remove_liquidity_one_coin(
            finalLpTokenAmount,
            index,
            data_.minCoinAmountReceived,
            address(this)
        );

        emit CurveSupplyStableswapNGSingleSideSupplyFuseExit(
            VERSION,
            address(curvePool),
            finalLpTokenAmount,
            data_.asset,
            coinAmountReceived
        );

        return (address(curvePool), coinAmountReceived);
    }

    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address curveStableswapNG = TypeConversionLib.toAddress(inputs[0]);
        address asset = TypeConversionLib.toAddress(inputs[1]);
        uint256 lpTokenAmount = TypeConversionLib.toUint256(inputs[2]);
        uint256 minCoinAmountReceived = TypeConversionLib.toUint256(inputs[3]);

        (address curveStableswapNGUsed, uint256 coinAmountReceived) = exit(
            CurveStableswapNGSingleSideSupplyFuseExitData({
                curveStableswapNG: ICurveStableswapNG(curveStableswapNG),
                lpTokenAmount: lpTokenAmount,
                asset: asset,
                minCoinAmountReceived: minCoinAmountReceived
            })
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(curveStableswapNGUsed);
        outputs[1] = TypeConversionLib.toBytes32(coinAmountReceived);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
