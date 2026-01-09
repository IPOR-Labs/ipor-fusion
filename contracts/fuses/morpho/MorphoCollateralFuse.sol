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
/// @param morphoMarketId The Morpho market ID (bytes32) to supply collateral to
/// @param collateralAmount The maximum amount of collateral tokens to supply (in collateral token decimals)
struct MorphoCollateralFuseEnterData {
    /// @notice The Morpho market ID to supply collateral to
    bytes32 morphoMarketId;
    /// @notice The maximum amount of collateral tokens to supply (in collateral token decimals)
    uint256 collateralAmount;
}

/// @notice Structure for exiting (withdrawCollateral) from the Morpho protocol
/// @param morphoMarketId The Morpho market ID (bytes32) to withdraw collateral from
/// @param collateralAmount The exact amount of collateral tokens to withdraw (in collateral token decimals)
struct MorphoCollateralFuseExitData {
    /// @notice The Morpho market ID to withdraw collateral from
    bytes32 morphoMarketId;
    /// @notice The exact amount of collateral tokens to withdraw (in collateral token decimals)
    uint256 collateralAmount;
}

/// @title MorphoCollateralFuse
/// @notice This contract allows users to supply and withdraw collateral to/from the Morpho protocol.
contract MorphoCollateralFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice Address of this fuse contract version
    /// @dev Immutable value set in constructor, used for tracking and versioning
    address public immutable VERSION;

    /// @notice Market ID this fuse operates on
    /// @dev Immutable value set in constructor, used to retrieve market substrates (Morpho Market IDs)
    uint256 public immutable MARKET_ID;

    /// @notice Morpho protocol contract address
    /// @dev Immutable value set in constructor, used for Morpho protocol interactions
    IMorpho public immutable MORPHO;

    /// @notice Emitted when collateral is supplied to Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the collateral token supplied
    /// @param market The Morpho market ID
    /// @param amount The amount of collateral tokens supplied
    event MorphoCollateralFuseEnter(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Emitted when collateral is withdrawn from Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the collateral token withdrawn
    /// @param market The Morpho market ID
    /// @param amount The amount of collateral tokens withdrawn
    event MorphoCollateralFuseExit(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Thrown when an unsupported Morpho market is accessed
    /// @param action The action being performed ("enter" or "exit")
    /// @param morphoMarketId The Morpho market ID that is not supported
    /// @custom:error MorphoCollateralUnsupportedMarket
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
    /// @dev Will revert if the requested amount exceeds available collateral or violates position health
    /// @param data_ The data structure containing market ID and collateral amount
    /// @return asset The address of the collateral token
    /// @return market The Morpho market ID
    /// @return amount The amount of collateral withdrawn
    function exit(
        MorphoCollateralFuseExitData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        if (data_.collateralAmount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoCollateralUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        MORPHO.withdrawCollateral(marketParams, data_.collateralAmount, address(this), address(this));

        asset = marketParams.collateralToken;
        market = data_.morphoMarketId;
        amount = data_.collateralAmount;

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
        uint256 collateralAmount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, bytes32 returnedMarket, uint256 returnedAmount) = exit(
            MorphoCollateralFuseExitData(morphoMarketId, collateralAmount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = returnedMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
