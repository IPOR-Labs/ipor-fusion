// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {ISilo} from "./ext/ISilo.sol";
import {ISiloConfig} from "./ext/ISiloConfig.sol";
import {SiloIndex} from "./SiloIndex.sol";
struct SiloV2BorrowFuseEnterData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to supply Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo underlying asset to supply
    uint256 siloAssetAmount;
}

struct SiloV2BorrowFuseExitData {
    /// @dev Silo Config address - contract that manages the Silo
    address siloConfig;
    /// @dev Specify which silo to supply Silo0 or Silo1
    SiloIndex siloIndex;
    /// @dev amount of Silo underlying asset to supply
    uint256 siloAssetAmount;
}

contract SiloV2BorrowFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @dev The version of the contract.
    address public immutable VERSION;
    /// @dev The unique identifier for IporFusionMarkets.
    uint256 public immutable MARKET_ID;

    error SiloV2BorrowFuseUnsupportedSiloConfig(string action, address siloConfig);

    event SiloV2BorrowFuseEvent(
        address version,
        uint256 marketId,
        address siloConfig,
        address silo,
        uint256 siloAssetAmountBorrowed,
        uint256 siloSharesBorrowed
    );

    event SiloV2BorrowFuseRepay(
        address version,
        uint256 marketId,
        address siloConfig,
        address silo,
        uint256 siloAssetAmountRepaid,
        uint256 siloSharesRepaid
    );

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the Fuse
    /// @param data_ The input data for entering the fuse
    /// @return siloConfig The silo config address
    /// @return silo The silo address
    /// @return siloAssetAmountBorrowed The amount of Silo underlying asset borrowed
    /// @return siloSharesBorrowed The amount of Silo shares borrowed
    function enter(
        SiloV2BorrowFuseEnterData memory data_
    ) public returns (address siloConfig, address silo, uint256 siloAssetAmountBorrowed, uint256 siloSharesBorrowed) {
        if (data_.siloAssetAmount == 0) {
            return (data_.siloConfig, address(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2BorrowFuseUnsupportedSiloConfig("enter", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        siloSharesBorrowed = ISilo(silo).borrow(data_.siloAssetAmount, address(this), address(this));
        siloAssetAmountBorrowed = data_.siloAssetAmount;
        siloConfig = data_.siloConfig;

        emit SiloV2BorrowFuseEvent(VERSION, MARKET_ID, siloConfig, silo, siloAssetAmountBorrowed, siloSharesBorrowed);
    }

    /// @notice Exits the Fuse
    /// @param data_ The input data for exiting the fuse
    /// @return siloConfig The silo config address
    /// @return silo The silo address
    /// @return siloAssetAmountRepaid The amount of Silo underlying asset repaid
    /// @return siloSharesRepaid The amount of Silo shares repaid
    function exit(
        SiloV2BorrowFuseExitData memory data_
    ) public returns (address siloConfig, address silo, uint256 siloAssetAmountRepaid, uint256 siloSharesRepaid) {
        if (data_.siloAssetAmount == 0) {
            return (data_.siloConfig, address(0), 0, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.siloConfig)) {
            revert SiloV2BorrowFuseUnsupportedSiloConfig("exit", data_.siloConfig);
        }

        (address silo0, address silo1) = ISiloConfig(data_.siloConfig).getSilos();

        silo = data_.siloIndex == SiloIndex.SILO0 ? silo0 : silo1;

        address siloAssetAddress = ISilo(silo).asset();

        ERC20(siloAssetAddress).forceApprove(silo, data_.siloAssetAmount);

        siloSharesRepaid = ISilo(silo).repay(data_.siloAssetAmount, address(this));
        siloAssetAmountRepaid = data_.siloAssetAmount;
        siloConfig = data_.siloConfig;

        ERC20(siloAssetAddress).forceApprove(silo, 0);

        emit SiloV2BorrowFuseRepay(VERSION, MARKET_ID, siloConfig, silo, siloAssetAmountRepaid, siloSharesRepaid);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address siloConfig = TypeConversionLib.toAddress(inputs[0]);
        SiloIndex siloIndex = SiloIndex(TypeConversionLib.toUint256(inputs[1]));
        uint256 siloAssetAmount = TypeConversionLib.toUint256(inputs[2]);

        (address returnedSiloConfig, address silo, uint256 siloAssetAmountBorrowed, uint256 siloSharesBorrowed) = enter(
            SiloV2BorrowFuseEnterData({siloConfig: siloConfig, siloIndex: siloIndex, siloAssetAmount: siloAssetAmount})
        );

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedSiloConfig);
        outputs[1] = TypeConversionLib.toBytes32(silo);
        outputs[2] = TypeConversionLib.toBytes32(siloAssetAmountBorrowed);
        outputs[3] = TypeConversionLib.toBytes32(siloSharesBorrowed);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address siloConfig = TypeConversionLib.toAddress(inputs[0]);
        SiloIndex siloIndex = SiloIndex(TypeConversionLib.toUint256(inputs[1]));
        uint256 siloAssetAmount = TypeConversionLib.toUint256(inputs[2]);

        (address returnedSiloConfig, address silo, uint256 siloAssetAmountRepaid, uint256 siloSharesRepaid) = exit(
            SiloV2BorrowFuseExitData({siloConfig: siloConfig, siloIndex: siloIndex, siloAssetAmount: siloAssetAmount})
        );

        bytes32[] memory outputs = new bytes32[](4);
        outputs[0] = TypeConversionLib.toBytes32(returnedSiloConfig);
        outputs[1] = TypeConversionLib.toBytes32(silo);
        outputs[2] = TypeConversionLib.toBytes32(siloAssetAmountRepaid);
        outputs[3] = TypeConversionLib.toBytes32(siloSharesRepaid);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
