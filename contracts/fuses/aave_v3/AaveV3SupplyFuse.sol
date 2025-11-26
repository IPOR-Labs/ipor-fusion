// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {IAavePoolDataProvider} from "./ext/IAavePoolDataProvider.sol";
import {IPool} from "./ext/IPool.sol";
import {IPoolAddressesProvider} from "./ext/IPoolAddressesProvider.sol";

/// @dev Struct for entering with supply to the Aave V3 protocol
struct AaveV3SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
    /// @notice user eMode category if pass value bigger than 255 is ignored and not set
    uint256 userEModeCategoryId;
}

/// @dev Struct for exiting with supply (redeem) from the Aave V3 protocol
struct AaveV3SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @title AaveV3SupplyFuse
/// @notice Fuse for Aave V3 protocol responsible for supplying and withdrawing assets from the Aave V3 protocol
/// @author IPOR Labs
contract AaveV3SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice The address of the Aave V3 Pool Addresses Provider
    address public immutable AAVE_V3_POOL_ADDRESSES_PROVIDER;

    /// @notice Emitted when entering the Aave V3 supply fuse
    /// @param version The address of the fuse version
    /// @param asset The address of the asset supplied
    /// @param amount The amount of the asset supplied
    /// @param userEModeCategoryId The user eMode category ID
    event AaveV3SupplyFuseEnter(
        address indexed version,
        address indexed asset,
        uint256 amount,
        uint256 userEModeCategoryId
    );

    /// @notice Emitted when exiting the Aave V3 supply fuse
    /// @param version The address of the fuse version
    /// @param asset The address of the asset withdrawn
    /// @param amount The amount of the asset withdrawn
    event AaveV3SupplyFuseExit(address version, address asset, uint256 amount);

    /// @notice Emitted when exiting the Aave V3 supply fuse fails
    /// @param version The address of the fuse version
    /// @param asset The address of the asset withdrawn
    /// @param amount The amount of the asset withdrawn
    event AaveV3SupplyFuseExitFailed(address version, address asset, uint256 amount);

    /// @notice Thrown when the asset is not supported by the fuse
    /// @param action The action being performed (enter/exit)
    /// @param asset The address of the asset
    error AaveV3SupplyFuseUnsupportedAsset(string action, address asset);

    /// @notice Constructor for AaveV3SupplyFuse
    /// @param marketId_ The Market ID associated with the Fuse
    /// @param aaveV3PoolAddressesProvider_ The address of the Aave V3 Pool Addresses Provider
    constructor(uint256 marketId_, address aaveV3PoolAddressesProvider_) {
        if (marketId_ == 0) {
            revert Errors.WrongValue();
        }
        if (aaveV3PoolAddressesProvider_ == address(0)) {
            revert Errors.WrongAddress();
        }

        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_V3_POOL_ADDRESSES_PROVIDER = aaveV3PoolAddressesProvider_;
    }

    /// @notice Enters (supplies) assets to Aave V3 protocol
    /// @param data_ Enter data containing asset address, amount to supply, and user eMode category ID
    /// @return asset The address of the supplied asset
    /// @return amount The amount of assets supplied
    function enter(AaveV3SupplyFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, data_.amount);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("enter", data_.asset);
        }

        IPool aavePool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());

        uint256 finalAmount = IporMath.min(ERC20(data_.asset).balanceOf(address(this)), data_.amount);

        ERC20(data_.asset).forceApprove(address(aavePool), finalAmount);

        aavePool.supply(data_.asset, finalAmount, address(this), 0);

        if (data_.userEModeCategoryId < uint256(type(uint8).max) + 1) {
            aavePool.setUserEMode(data_.userEModeCategoryId.toUint8());
        }

        emit AaveV3SupplyFuseEnter(VERSION, data_.asset, finalAmount, data_.userEModeCategoryId);

        return (data_.asset, finalAmount);
    }

    /// @notice Enters (supplies) assets to Aave V3 protocol using transient storage for inputs
    /// @dev Reads asset, amount, and userEModeCategoryId from transient storage
    /// @dev Writes returned asset and amount to transient storage outputs
    function enterTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 userEModeCategoryIdBytes32 = TransientStorageLib.getInput(VERSION, 2);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);
        uint256 userEModeCategoryId = TypeConversionLib.toUint256(userEModeCategoryIdBytes32);

        AaveV3SupplyFuseEnterData memory data = AaveV3SupplyFuseEnterData({
            asset: asset,
            amount: amount,
            userEModeCategoryId: userEModeCategoryId
        });

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (withdraws) assets from Aave V3 protocol
    /// @param data_ Exit data containing asset address and amount to withdraw
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function exit(AaveV3SupplyFuseExitData calldata data_) public returns (address asset, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Exits (withdraws) assets from Aave V3 protocol using transient storage for inputs
    /// @dev Reads asset and amount from transient storage
    /// @dev Writes returned asset and amount to transient storage outputs
    function exitTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);

        AaveV3SupplyFuseExitData memory data = AaveV3SupplyFuseExitData({asset: asset, amount: amount});

        (address returnedAsset, uint256 returnedAmount) = _exit(data, false);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Performs instant withdrawal from Aave V3 protocol with exception handling
    /// @param params_ Array of parameters: params[0] - amount in underlying asset, params[1] - asset address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(AaveV3SupplyFuseExitData(asset, amount), true);
    }

    /// @notice Internal function to exit (withdraw) assets from Aave V3 protocol
    /// @param data_ Exit data containing asset address and amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function _exit(
        AaveV3SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, data_.amount);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV3SupplyFuseUnsupportedAsset("exit", data_.asset);
        }

        (address aTokenAddress, , ) = IAavePoolDataProvider(
            IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPoolDataProvider()
        ).getReserveTokensAddresses(data_.asset);

        uint256 finalAmount = IporMath.min(ERC20(aTokenAddress).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        return _performWithdraw(data_.asset, finalAmount, catchExceptions_);
    }

    /// @notice Performs the actual withdrawal from Aave V3 protocol
    /// @param asset_ The address of the asset to withdraw
    /// @param finalAmount_ The amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function _performWithdraw(
        address asset_,
        uint256 finalAmount_,
        bool catchExceptions_
    ) private returns (address asset, uint256 amount) {
        IPool aavePool = IPool(IPoolAddressesProvider(AAVE_V3_POOL_ADDRESSES_PROVIDER).getPool());

        if (catchExceptions_) {
            try aavePool.withdraw(asset_, finalAmount_, address(this)) returns (uint256 withdrawnAmount) {
                emit AaveV3SupplyFuseExit(VERSION, asset_, withdrawnAmount);
                return (asset_, withdrawnAmount);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit AaveV3SupplyFuseExitFailed(VERSION, asset_, finalAmount_);
                return (asset_, finalAmount_);
            }
        } else {
            uint256 withdrawnAmount = aavePool.withdraw(asset_, finalAmount_, address(this));
            emit AaveV3SupplyFuseExit(VERSION, asset_, withdrawnAmount);
            return (asset_, withdrawnAmount);
        }
    }
}
