// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.20;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {ICurveStableswapNG} from "./ext/ICurveStableswapNG.sol";
import {IFuse} from "../IFuse.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

struct CurveStableswapNGSingleSideSupplyFuseEnterData {
    /// @notice asset to deposit
    address asset;
    /// @notice List of amounts of coins to deposit
    uint256[] amounts;
    /// @notice Minimum amount of LP tokens to mint from the deposit
    uint256 minMintAmount;
}

struct CurveStableswapNGSingleSideSupplyFuseExitData {
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
    ICurveStableswapNG public immutable CURVE_STABLESWAP_NG;

    event CurveSupplyStableswapNGSingleSideSupplyEnterFuse(
        address indexed version,
        address indexed asset,
        uint256[] amounts,
        uint256 minMintAmount
    );

    event CurveSupplyStableswapNGSingleSideSupplyExitFuse(
        address indexed version,
        uint256 burnAmount,
        address asset,
        uint256 minReceived
    );

    error CurveStableswapNGSingleSideSupplyFuseUnsupportedAsset(address asset, string errorCode);
    error CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(address asset, string errorCode);
    error CurveStableswapNGSingleSideSupplyFuseUnexpectedNumberOfTokens();
    error CurveStableswapNGSingleSideSupplyFuseAllZeroAmounts();
    error CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount();
    error CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinMintAmount(
        uint256 expectedMintAmount,
        uint256 minMintAmount
    );
    error CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinReceivedAmount(
        uint256 expectedReceiveAmount,
        uint256 minReceivedAmount
    );

    constructor(uint256 marketIdInput, address curveStableswapNGInput) {
        VERSION = address(this);
        MARKET_ID = marketIdInput;
        CURVE_STABLESWAP_NG = ICurveStableswapNG(curveStableswapNGInput);
    }

    function enter(bytes calldata data) external override {
        _enter(abi.decode(data, (CurveStableswapNGSingleSideSupplyFuseEnterData)));
    }

    /// @dev technical method to generate ABI
    function enter(CurveStableswapNGSingleSideSupplyFuseEnterData memory data) external {
        _enter(data);
    }

    function _enter(CurveStableswapNGSingleSideSupplyFuseEnterData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(CURVE_STABLESWAP_NG))) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedAsset(
                address(CURVE_STABLESWAP_NG),
                Errors.UNSUPPORTED_ASSET
            );
        }
        if (data.amounts.length != CURVE_STABLESWAP_NG.N_COINS()) {
            revert CurveStableswapNGSingleSideSupplyFuseUnexpectedNumberOfTokens();
        }
        bool supportedPoolAsset = false;
        bool hasNonZeroAmount = false;
        for (uint256 i; i < CURVE_STABLESWAP_NG.N_COINS(); ++i) {
            if (CURVE_STABLESWAP_NG.coins(i) == data.asset) {
                supportedPoolAsset = true;
                ERC20(data.asset).forceApprove(address(CURVE_STABLESWAP_NG), data.amounts[i]);
            }
            if (data.amounts[i] > 0) {
                hasNonZeroAmount = true;
            }
        }
        if (!supportedPoolAsset) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }
        if (!hasNonZeroAmount) {
            revert CurveStableswapNGSingleSideSupplyFuseAllZeroAmounts();
        }
        uint256 expectedMintAmount = CURVE_STABLESWAP_NG.calc_token_amount(data.amounts, true);
        if (expectedMintAmount < data.minMintAmount) {
            revert CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinMintAmount(
                expectedMintAmount,
                data.minMintAmount
            );
        }
        CURVE_STABLESWAP_NG.add_liquidity(data.amounts, data.minMintAmount, address(this));
        emit CurveSupplyStableswapNGSingleSideSupplyEnterFuse(VERSION, data.asset, data.amounts, data.minMintAmount);
    }

    function exit(bytes calldata data) external override {
        _exit(abi.decode(data, (CurveStableswapNGSingleSideSupplyFuseExitData)));
    }

    /// @dev technical method to generate ABI
    function exit(CurveStableswapNGSingleSideSupplyFuseExitData calldata data) external {
        _exit(data);
    }

    function _exit(CurveStableswapNGSingleSideSupplyFuseExitData memory data) internal {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, address(CURVE_STABLESWAP_NG))) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedAsset(
                address(CURVE_STABLESWAP_NG),
                Errors.UNSUPPORTED_ASSET
            );
        }
        if (data.burnAmount == 0) {
            revert CurveStableswapNGSingleSideSupplyFuseZeroBurnAmount();
        }
        bool supportedPoolAsset = false;
        int128 index;
        for (uint256 i; i < CURVE_STABLESWAP_NG.N_COINS(); ++i) {
            if (CURVE_STABLESWAP_NG.coins(i) == data.asset) {
                require(i < 2 ** 127, "Index exceeds int128 range");
                index = int128(int256(i));
                supportedPoolAsset = true;
                break;
            }
        }
        if (!supportedPoolAsset) {
            revert CurveStableswapNGSingleSideSupplyFuseUnsupportedPoolAsset(data.asset, Errors.UNSUPPORTED_ASSET);
        }
        uint256 expectedReceivedAmount = CURVE_STABLESWAP_NG.calc_withdraw_one_coin(data.burnAmount, index);
        if (expectedReceivedAmount < data.minReceived) {
            revert CurveStableswapNGSingleSideSupplyFuseUnableToMeetMinReceivedAmount(
                expectedReceivedAmount,
                data.minReceived
            );
        }
        CURVE_STABLESWAP_NG.remove_liquidity_one_coin(data.burnAmount, index, data.minReceived, address(this));
        emit CurveSupplyStableswapNGSingleSideSupplyExitFuse(VERSION, data.burnAmount, data.asset, data.minReceived);
    }
}
