// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct CurveStableswapNGSingleSideSupplyFuseEnterData {
    /// @notice Curve pool contract to enter
    ICurveStableswapNG curveStableswapNG;
    /// @notice asset to deposit
    address asset;
    /// @notice Amount of the asset to deposit
    uint256 amount;
    /// @notice Minimum amount of LP tokens to mint from the deposit
    uint256 minMintAmount;
}

struct CurveStableswapNGSingleSideSupplyFuseExitData {
    /// @notice Curve pool contract to exit
    ICurveStableswapNG curveStableswapNG;
    /// @notice Amount of LP tokens to burn
    uint256 burnAmount;
    /// @notice Address of the asset to withdraw
    address asset;
    /// @notice Minimum amount of the coin to receive
    uint256 minReceived;
}

contract CurveStableswapNGSingleSideSupplyFuse is IFuse {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    event CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
        address version,
        address curvePool,
        address asset,
        uint256 amount,
        uint256 minMintAmount
    );

    event CurveSupplyStableswapNGSingleSideSupplyExitFuse(
        address version,
        address curvePool,
        uint256 burnAmount,
        address asset,
        uint256 minReceived
    );

    error CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address poolAddress);
    error CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address asset);
    error CurveStableswapNGSingleSideSupplyFuseAllZeroAmounts();
    error CurveStableswapNGSingleSideSupplyFuseZeroAmount();
    error CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount();

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(bytes calldata data_) external override {
        _enter(abi.decode(data_, (CurveStableswapNGSingleSideSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CurveStableswapNGSingleSideSupplyFuseEnterData memory data_) external {
        _enter(data_);
    }

    function _enter(CurveStableswapNGSingleSideSupplyFuseEnterData memory data_) internal {
        ICurveStableswapNG curvePool = ICurveStableswapNG(data_.curveStableswapNG);
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(curvePool))) {
            /// @notice substrateAsAsset here refers to the Curve pool LP token, not the underlying asset of the Plasma Vault
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address(curvePool));
        }
        uint256 nCoins = curvePool.N_COINS();
        uint256[] memory amounts = new uint256[](nCoins);
        bool supportedPoolAsset = false;
        if (data_.amount == 0) {
            revert CurveStableswapNGSingleSideSupplyFuseZeroAmount();
        }
        for (uint256 i; i < nCoins; ++i) {
            if (curvePool.coins(i) == data_.asset) {
                supportedPoolAsset = true;
                amounts[i] = data_.amount;
                ERC20(data_.asset).forceApprove(address(curvePool), data_.amount);
            }
        }
        if (!supportedPoolAsset) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(data_.asset);
        }
        curvePool.add_liquidity(amounts, data_.minMintAmount, address(this));
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
            VERSION,
            address(curvePool),
            data_.asset,
            data_.amount,
            data_.minMintAmount
        );
    }

    function exit(bytes calldata data_) external override {
        _exit(abi.decode(data_, (CurveStableswapNGSingleSideSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CurveStableswapNGSingleSideSupplyFuseExitData calldata data_) external {
        _exit(data_);
    }

    function _exit(CurveStableswapNGSingleSideSupplyFuseExitData memory data_) internal {
        ICurveStableswapNG curvePool = ICurveStableswapNG(data_.curveStableswapNG);
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(curvePool))) {
            /// @notice substrateAsAsset here refers to the Curve pool LP token, not the underlying asset of the Plasma Vault
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPool(address(curvePool));
        }
        if (data_.burnAmount == 0) {
            revert CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount();
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
        curvePool.remove_liquidity_one_coin(data_.burnAmount, index, data_.minReceived, address(this));
        emit CurveSupplyStableswapNGSingleSideSupplyExitFuse(
            VERSION,
            address(curvePool),
            data_.burnAmount,
            data_.asset,
            data_.minReceived
        );
    }
}
