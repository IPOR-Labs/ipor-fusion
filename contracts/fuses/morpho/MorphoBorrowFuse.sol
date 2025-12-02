// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @dev Data structure for entering a Morpho borrow fuse.
struct MorphoBorrowFuseEnterData {
    /// @dev The ID of the Morpho market.
    bytes32 morphoMarketId;
    /// @dev The amount to borrow.
    uint256 amountToBorrow;
    /// @dev The shares to borrow.
    uint256 sharesToBorrow;
}

/// @dev Data structure for exiting a Morpho borrow fuse, repay on Morpho.
struct MorphoBorrowFuseExitData {
    /// @dev The ID of the Morpho market.
    bytes32 morphoMarketId;
    /// @dev The amount to repay in borrow asset decimals .
    uint256 amountToRepay;
    /// @dev The shares to repay in morpho decimals.
    uint256 sharesToRepay;
}

contract MorphoBorrowFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;
    /// @dev The address of the Morpho contract.
    IMorpho public immutable MORPHO;

    error MorphoBorrowFuseUnsupportedMarket(string action, bytes32 morphoMarketId);

    event MorphoBorrowFuseEvent(
        address version,
        uint256 marketId,
        bytes32 morphoMarket,
        uint256 assetsBorrowed,
        uint256 sharesBorrowed
    );

    event MorphoBorrowFuseRepay(
        address version,
        uint256 marketId,
        bytes32 morphoMarket,
        uint256 assetsRepaid,
        uint256 sharesRepaid
    );

    constructor(uint256 marketId_, address morpho_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MORPHO = IMorpho(morpho_);
    }

    /// @notice Borrows assets from Morpho protocol
    /// @param data_ Struct containing morphoMarketId, amountToBorrow, and sharesToBorrow
    /// @return marketId The unique identifier for IporFusionMarkets
    /// @return morphoMarket The ID of the Morpho market
    /// @return assetsBorrowed The amount of assets borrowed
    /// @return sharesBorrowed The amount of shares borrowed
    function enter(
        MorphoBorrowFuseEnterData memory data_
    ) public returns (uint256 marketId, bytes32 morphoMarket, uint256 assetsBorrowed, uint256 sharesBorrowed) {
        if (data_.amountToBorrow == 0 && data_.sharesToBorrow == 0) {
            return (MARKET_ID, bytes32(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoBorrowFuseUnsupportedMarket("enter", data_.morphoMarketId);
        }

        (assetsBorrowed, sharesBorrowed) = MORPHO.borrow(
            MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId)),
            data_.amountToBorrow,
            data_.sharesToBorrow,
            address(this),
            address(this)
        );

        marketId = MARKET_ID;
        morphoMarket = data_.morphoMarketId;

        emit MorphoBorrowFuseEvent(VERSION, marketId, morphoMarket, assetsBorrowed, sharesBorrowed);
    }

    /// @notice Repays borrowed assets to Morpho protocol
    /// @param data_ Struct containing morphoMarketId, amountToRepay, and sharesToRepay
    /// @return marketId The unique identifier for IporFusionMarkets
    /// @return morphoMarket The ID of the Morpho market
    /// @return assetsRepaid The amount of assets repaid
    /// @return sharesRepaid The amount of shares repaid
    function exit(
        MorphoBorrowFuseExitData memory data_
    ) public returns (uint256 marketId, bytes32 morphoMarket, uint256 assetsRepaid, uint256 sharesRepaid) {
        if (data_.amountToRepay == 0 && data_.sharesToRepay == 0) {
            return (MARKET_ID, bytes32(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, data_.morphoMarketId)) {
            revert MorphoBorrowFuseUnsupportedMarket("exit", data_.morphoMarketId);
        }

        MarketParams memory marketParams = MORPHO.idToMarketParams(Id.wrap(data_.morphoMarketId));

        /// @dev Approve the loan token to be spent by MORPHO, to max value because cost of calculation in case when want to send shears to repay
        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), type(uint256).max);

        (assetsRepaid, sharesRepaid) = MORPHO.repay(
            marketParams,
            data_.amountToRepay,
            data_.sharesToRepay,
            address(this),
            bytes("")
        );

        ERC20(marketParams.loanToken).forceApprove(address(MORPHO), 0);

        marketId = MARKET_ID;
        morphoMarket = data_.morphoMarketId;

        emit MorphoBorrowFuseRepay(VERSION, marketId, morphoMarket, assetsRepaid, sharesRepaid);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads morphoMarketId, amountToBorrow, and sharesToBorrow from transient storage
    /// @dev Writes returned marketId, morphoMarket, assetsBorrowed, and sharesBorrowed to transient storage outputs
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 amountToBorrow = TypeConversionLib.toUint256(inputs[1]);
        uint256 sharesToBorrow = TypeConversionLib.toUint256(inputs[2]);

        (
            uint256 returnedMarketId,
            bytes32 returnedMorphoMarket,
            uint256 returnedAssetsBorrowed,
            uint256 returnedSharesBorrowed
        ) = enter(MorphoBorrowFuseEnterData(morphoMarketId, amountToBorrow, sharesToBorrow));

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedMarketId);
        outputs[1] = returnedMorphoMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAssetsBorrowed);
        outputs[3] = TypeConversionLib.toBytes32(returnedSharesBorrowed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads morphoMarketId, amountToRepay, and sharesToRepay from transient storage
    /// @dev Writes returned marketId, morphoMarket, assetsRepaid, and sharesRepaid to transient storage outputs
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        bytes32 morphoMarketId = inputs[0];
        uint256 amountToRepay = TypeConversionLib.toUint256(inputs[1]);
        uint256 sharesToRepay = TypeConversionLib.toUint256(inputs[2]);

        (
            uint256 returnedMarketId,
            bytes32 returnedMorphoMarket,
            uint256 returnedAssetsRepaid,
            uint256 returnedSharesRepaid
        ) = exit(MorphoBorrowFuseExitData(morphoMarketId, amountToRepay, sharesToRepay));

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedMarketId);
        outputs[1] = returnedMorphoMarket;
        outputs[2] = TypeConversionLib.toBytes32(returnedAssetsRepaid);
        outputs[3] = TypeConversionLib.toBytes32(returnedSharesRepaid);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
