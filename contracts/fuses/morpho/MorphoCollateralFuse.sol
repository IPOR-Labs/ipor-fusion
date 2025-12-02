// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Structure for entering (supplyCollateral) to the Morpho protocol
struct MorphoCollateralFuseEnterData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply (in collateral token decimals)
    uint256 collateralAmount;
}

/// @notice Structure for exiting (withdrawCollateral) from the Morpho protocol
struct MorphoCollateralFuseExitData {
    // vault address
    bytes32 morphoMarketId;
    // max amount to supply (in collateral token decimals)`
    uint256 maxCollateralAmount;
}

/// @title MorphoCollateralFuse
/// @notice This contract allows users to supply and withdraw collateral to/from the Morpho protocol.
contract MorphoCollateralFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IMorpho public immutable MORPHO;

    event MorphoCollateralFuseEnter(address version, address asset, bytes32 market, uint256 amount);
    event MorphoCollateralFuseExit(address version, address asset, bytes32 market, uint256 amount);

    error MorphoCollateralUnsupportedMarket(string action, bytes32 morphoMarketId);

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /// @notice Supplies collateral to the Morpho protocol
    /// @param data_ The data structure containing market ID and collateral amount
    /// @return asset The address of the collateral token
    /// @return market The Morpho market ID
    /// @return amount The amount of collateral supplied
    function enter(
        MorphoCollateralFuseEnterData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        if (data_.collateralAmount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoCollateralUnsupportedMarket("enter", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        uint256 collateralTokenBalance = ERC20(marketParams.collateralToken).balanceOf(address(this));

        uint256 transferAmount = data_.collateralAmount <= collateralTokenBalance
            ? data_.collateralAmount
            : collateralTokenBalance;

        ERC20(marketParams.collateralToken).forceApprove(address(MORPHO), transferAmount);

        MORPHO.supplyCollateral(marketParams, transferAmount, address(this), bytes(""));

        asset = marketParams.collateralToken;
        market = data_.morphoMarketId;
        amount = transferAmount;

        emit MorphoCollateralFuseEnter(VERSION, asset, market, amount);
    }

    /// @notice Withdraws collateral from the Morpho protocol
    /// @param data_ The data structure containing market ID and max collateral amount
    /// @return asset The address of the collateral token
    /// @return market The Morpho market ID
    /// @return amount The amount of collateral withdrawn
    function exit(
        MorphoCollateralFuseExitData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        if (data_.maxCollateralAmount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoCollateralUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        MORPHO.withdrawCollateral(marketParams, data_.maxCollateralAmount, address(this), address(this));

        asset = marketParams.collateralToken;
        market = data_.morphoMarketId;
        amount = data_.maxCollateralAmount;

        emit MorphoCollateralFuseExit(VERSION, asset, market, amount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 collateralAmount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, bytes32 returnedMarket, uint256 returnedAmount) = enter(
            MorphoCollateralFuseEnterData(morphoMarketId, collateralAmount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = returnedMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 maxCollateralAmount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, bytes32 returnedMarket, uint256 returnedAmount) = exit(
            MorphoCollateralFuseExitData(morphoMarketId, maxCollateralAmount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = returnedMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
