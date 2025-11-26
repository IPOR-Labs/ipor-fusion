// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";

/// @notice Structure for entering (borrow) to the Aave V3 protocol
struct AaveV3BorrowFuseEnterData {
    /// @notice asset address to borrow
    address asset;
    /// @notice asset amount to borrow
    uint256 amount;
}

/// @notice Structure for exiting (repay) from the Aave V3 protocol
struct AaveV3BorrowFuseExitData {
    /// @notice borrowed asset address to repay
    address asset;
    /// @notice borrowed asset amount to repay
    uint256 amount;
}

/// @title Fuse Aave V3 Borrow protocol responsible for borrowing and repaying assets in variable interest rate from the Aave V3 protocol based on preconfigured market substrates
/// @notice Fuse for Aave V3 protocol responsible for borrowing and repaying assets from the Aave V3 protocol
/// @dev Substrates in this fuse are the assets that are used in the Aave V3 protocol for a given MARKET_ID
/// @author IPOR Labs
contract AaveV3BorrowFuse is IFuseCommon {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice interest rate mode = 2 in Aave V3 means variable interest rate.
    uint256 public constant INTEREST_RATE_MODE = 2;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aave V3 Pool Addresses Provider
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @notice Emitted when entering the Aave V3 borrow fuse
    /// @param version The address of the fuse version
    /// @param asset The address of the asset borrowed
    /// @param amount The amount of the asset borrowed
    /// @param interestRateMode The interest rate mode (2 for variable)
    event AaveV3BorrowFuseEnter(address version, address asset, uint256 amount, uint256 interestRateMode);

    /// @notice Emitted when exiting the Aave V3 borrow fuse (repay)
    /// @param version The address of the fuse version
    /// @param asset The address of the asset repaid
    /// @param repaidAmount The amount of the asset repaid
    /// @param interestRateMode The interest rate mode (2 for variable)
    event AaveV3BorrowFuseExit(address version, address asset, uint256 repaidAmount, uint256 interestRateMode);

    error AaveV3BorrowFuseUnsupportedAsset(string action, address asset);

    /// @notice Constructor for AaveV3BorrowFuse
    /// @param marketId_ The Market ID associated with the Fuse
    /// @param aaveV3PoolAddressesProvider_ The address of the Aave V3 Pool Addresses Provider
    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Enters (borrows) assets from Aave V3 protocol
    /// @param data_ Enter data containing asset address and amount to borrow
    /// @return asset The address of the borrowed asset
    /// @return amount The amount of assets borrowed
    function enter(AaveV3BorrowFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("enter", data_.asset);
        }

        IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool()).borrow(
            data_.asset,
            data_.amount,
            INTEREST_RATE_MODE,
            0,
            address(this)
        );

        emit AaveV3BorrowFuseEnter(VERSION, data_.asset, data_.amount, INTEREST_RATE_MODE);

        return (data_.asset, data_.amount);
    }

    /// @notice Enters (borrows) assets from Aave V3 protocol using transient storage for inputs
    /// @dev Reads asset and amount from transient storage
    /// @dev Writes returned asset and amount to transient storage outputs
    function enterTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);

        AaveV3BorrowFuseEnterData memory data = AaveV3BorrowFuseEnterData({asset: asset, amount: amount});

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (repays) assets to Aave V3 protocol
    /// @param data_ Exit data containing asset address and amount to repay
    /// @return asset The address of the repaid asset
    /// @return amount The amount of assets repaid
    function exit(AaveV3BorrowFuseExitData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3BorrowFuseUnsupportedAsset("exit", data_.asset);
        }

        address aavePool = IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool();

        ERC20(data_.asset).forceApprove(aavePool, data_.amount);

        uint256 repaidAmount = IPool(aavePool).repay(data_.asset, data_.amount, INTEREST_RATE_MODE, address(this));

        emit AaveV3BorrowFuseExit(VERSION, data_.asset, repaidAmount, INTEREST_RATE_MODE);

        return (data_.asset, repaidAmount);
    }

    /// @notice Exits (repays) assets to Aave V3 protocol using transient storage for inputs
    /// @dev Reads asset and amount from transient storage
    /// @dev Writes returned asset and amount to transient storage outputs
    function exitTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);

        AaveV3BorrowFuseExitData memory data = AaveV3BorrowFuseExitData({asset: asset, amount: amount});

        (address returnedAsset, uint256 returnedAmount) = exit(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
