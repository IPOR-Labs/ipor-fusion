// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";

/// @notice Structure for entering (supply) to the Morpho protocol
/// @param morphoMarketId The Morpho market ID (bytes32) to supply assets to
/// @param amount The maximum amount of tokens to supply to the Morpho protocol
struct MorphoSupplyFuseEnterData {
    /// @notice The Morpho market ID to supply assets to
    bytes32 morphoMarketId;
    /// @notice The maximum amount of tokens to supply
    uint256 amount;
}

/// @notice Structure for exiting (withdraw) from the Morpho protocol
/// @param morphoMarketId The Morpho market ID (bytes32) to withdraw assets from
/// @param amount The amount of assets to withdraw from the Morpho protocol
struct MorphoSupplyFuseExitData {
    /// @notice The Morpho market ID to withdraw assets from
    bytes32 morphoMarketId;
    /// @notice The amount of assets to withdraw
    uint256 amount;
}

/// @title Fuse Morpho Supply protocol responsible for supplying and withdrawing assets from the Morpho protocol based on preconfigured market substrates
/// @dev Substrates in this fuse are the Morpho Market IDs that are used in the Morpho protocol for a given MARKET_ID
contract MorphoSupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    /// @notice Morpho protocol contract address
    /// @dev Immutable value set in constructor, used for Morpho protocol interactions
    IMorpho public immutable MORPHO;

    /// @notice Emitted when assets are supplied to Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset supplied
    /// @param market The Morpho market ID
    /// @param amount The amount of assets supplied
    event MorphoSupplyFuseEnter(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Emitted when assets are withdrawn from Morpho protocol
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset withdrawn
    /// @param market The Morpho market ID
    /// @param amount The amount of assets withdrawn
    event MorphoSupplyFuseExit(address version, address asset, bytes32 market, uint256 amount);

    /// @notice Emitted when withdrawal from Morpho protocol fails
    /// @param version The address of this fuse contract version
    /// @param asset The address of the asset that failed to withdraw
    /// @param market The Morpho market ID
    event MorphoSupplyFuseExitFailed(address version, address asset, bytes32 market);

    /// @notice Thrown when an unsupported Morpho market is accessed
    /// @param action The action being performed ("enter" or "exit")
    /// @param morphoMarketId The Morpho market ID that is not supported
    /// @custom:error MorphoSupplyFuseUnsupportedMarket
    error MorphoSupplyFuseUnsupportedMarket(string action, bytes32 morphoMarketId);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /// @notice Supply assets to Morpho protocol
    /// @param data_ Struct containing morphoMarketId and amount to supply
    /// @return asset Asset address supplied
    /// @return market Morpho market ID
    /// @return amount Amount supplied
    function enter(
        MorphoSupplyFuseEnterData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        if (data_.amount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("enter", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), data_.amount);

        (uint256 assetsSupplied, ) = MORPHO.supply(marketParams, data_.amount, 0, address(this), bytes(""));

        asset = marketParams.loanToken;
        market = data_.morphoMarketId;
        amount = assetsSupplied;

        emit MorphoSupplyFuseEnter(VERSION, asset, market, amount);
    }

    /// @notice Withdraw assets from Morpho protocol
    /// @param data_ Struct containing morphoMarketId and amount to withdraw
    /// @return asset Asset address withdrawn
    /// @return market Morpho market ID
    /// @return amount Amount withdrawn
    function exit(
        MorphoSupplyFuseExitData memory data_
    ) public returns (address asset, bytes32 market, uint256 amount) {
        return _exit(data_, false);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - Morpho market id
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        bytes32 morphoMarketId = params_[1];

        _exit(MorphoSupplyFuseExitData(morphoMarketId, amount), true);
    }

    function _exit(
        MorphoSupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, bytes32 market, uint256 amount) {
        if (data_.amount == 0) {
            return (address(0), bytes32(0), 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoSupplyFuseUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));
        Id id = marketParams.id();

        MORPHO.accrueInterest(marketParams);

        uint256 totalSupplyAssets = MORPHO.totalSupplyAssets(id);
        uint256 totalSupplyShares = MORPHO.totalSupplyShares(id);

        uint256 shares = MORPHO.supplyShares(id, address(this));

        if (shares == 0) {
            return (address(0), bytes32(0), 0);
        }

        uint256 assetsMax = shares.toAssetsDown(totalSupplyAssets, totalSupplyShares);

        if (assetsMax == 0) {
            return (address(0), bytes32(0), 0);
        }

        asset = marketParams.loanToken;
        market = data_.morphoMarketId;

        if (data_.amount >= assetsMax) {
            amount = _performWithdraw(marketParams, data_.morphoMarketId, 0, shares, catchExceptions_);
        } else {
            amount = _performWithdraw(marketParams, data_.morphoMarketId, data_.amount, 0, catchExceptions_);
        }
    }

    function _performWithdraw(
        MarketParams memory marketParams_,
        bytes32 morphoMarketId_,
        uint256 assets_,
        uint256 shares_,
        bool catchExceptions_
    ) private returns (uint256 amount) {
        if (catchExceptions_) {
            try MORPHO.withdraw(marketParams_, assets_, shares_, address(this), address(this)) returns (
                uint256 assetsWithdrawn,
                uint256 /* sharesWithdrawn */
            ) {
                amount = assetsWithdrawn;
                emit MorphoSupplyFuseExit(VERSION, marketParams_.loanToken, morphoMarketId_, amount);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                amount = 0;
                emit MorphoSupplyFuseExitFailed(VERSION, marketParams_.loanToken, morphoMarketId_);
            }
        } else {
            (uint256 assetsWithdrawn, ) = MORPHO.withdraw(
                marketParams_,
                assets_,
                shares_,
                address(this),
                address(this)
            );
            amount = assetsWithdrawn;
            emit MorphoSupplyFuseExit(VERSION, marketParams_.loanToken, morphoMarketId_, amount);
        }
    }

    /**
     * @notice Enters the Fuse using transient storage for parameters
     * @dev Reads morphoMarketId and amount from transient storage inputs.
     *      Writes returned asset, market, and amount to transient storage outputs.
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, bytes32 returnedMarket, uint256 returnedAmount) = enter(
            MorphoSupplyFuseEnterData(morphoMarketId, amount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = returnedMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Exits the Fuse using transient storage for parameters
     * @dev Reads morphoMarketId and amount from transient storage inputs.
     *      Writes returned asset, market, and amount to transient storage outputs.
     */
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedAsset, bytes32 returnedMarket, uint256 returnedAmount) = exit(
            MorphoSupplyFuseExitData(morphoMarketId, amount)
        );

        bytes32[] memory outputs = new bytes32[](3);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = returnedMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
