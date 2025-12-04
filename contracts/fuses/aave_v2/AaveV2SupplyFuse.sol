// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AaveLendingPoolV2, ReserveData} from "./ext/AaveLendingPoolV2.sol";
import {AaveConstantsEthereum} from "./AaveConstantsEthereum.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @dev Struct for entering with supply to the Aave V2 protocol
struct AaveV2SupplyFuseEnterData {
    /// @notice asset address to supply
    address asset;
    /// @notice asset amount to supply
    uint256 amount;
}

/// @dev Struct for exiting with supply (redeem) from the Aave V2 protocol
struct AaveV2SupplyFuseExitData {
    /// @notice asset address to withdraw
    address asset;
    /// @notice asset amount to withdraw
    uint256 amount;
}

/// @dev Fuse for Aave V2 protocol responsible for supplying and withdrawing assets from the Aave V2 protocol
contract AaveV2SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    AaveLendingPoolV2 public immutable AAVE_POOL;

    event AaveV2SupplyFuseEnter(address version, address asset, uint256 amount);
    event AaveV2SupplyFuseExit(address version, address asset, uint256 amount);
    event AaveV2SupplyFuseExitFailed(address version, address asset, uint256 amount);

    error AaveV2SupplyFuseUnsupportedAsset(address asset);

    constructor(uint256 marketId_, address aavePool_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        AAVE_POOL = AaveLendingPoolV2(aavePool_);
    }

    /// @notice Enters (supplies) assets to Aave V2 protocol
    /// @param data_ Enter data containing asset address and amount to supply
    /// @return asset The address of the supplied asset
    /// @return amount The amount of assets supplied
    function enter(AaveV2SupplyFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, data_.amount);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data_.asset);
        }

        ERC20(data_.asset).forceApprove(address(AAVE_POOL), data_.amount);

        AAVE_POOL.deposit(data_.asset, data_.amount, address(this), 0);

        emit AaveV2SupplyFuseEnter(VERSION, data_.asset, data_.amount);

        return (data_.asset, data_.amount);
    }

    /// @notice Enters (supplies) assets to Aave V2 protocol using transient storage for inputs
    /// @dev Reads asset and amount from transient storage at indices 0 and 1 respectively
    /// @dev Writes returned asset and amount to transient storage outputs
    function enterTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address asset = TypeConversionLib.toAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);

        AaveV2SupplyFuseEnterData memory data = AaveV2SupplyFuseEnterData({asset: asset, amount: amount});

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (withdraws) assets from Aave V2 protocol
    /// @param data_ Exit data containing asset address and amount to withdraw
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function exit(AaveV2SupplyFuseExitData calldata data_) external returns (address asset, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Exits (withdraws) assets from Aave V2 protocol using transient storage for inputs
    /// @dev Reads asset and amount from transient storage at indices 0 and 1 respectively
    /// @dev Writes returned asset and amount to transient storage outputs
    function exitTransient() external {
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 1);

        address asset = TypeConversionLib.toAddress(assetBytes32);
        uint256 amount = TypeConversionLib.toUint256(amountBytes32);

        AaveV2SupplyFuseExitData memory data = AaveV2SupplyFuseExitData({asset: asset, amount: amount});

        (address returnedAsset, uint256 returnedAmount) = _exit(data, false);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Performs instant withdrawal from Aave V2 protocol with exception handling
    /// @param params_ Array of parameters: params[0] - amount in underlying asset, params[1] - asset address
    /// @dev Uses catchExceptions_ = true to handle potential withdrawal failures gracefully
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(AaveV2SupplyFuseExitData(asset, amount), true);
    }

    /// @notice Internal function to exit (withdraw) assets from Aave V2 protocol
    /// @param data_ Exit data containing asset address and amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn (or requested amount if withdrawal failed and catchExceptions_ is true)
    function _exit(
        AaveV2SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, data_.amount);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.asset)) {
            revert AaveV2SupplyFuseUnsupportedAsset(data_.asset);
        }
        uint256 amountToWithdraw = data_.amount;

        ReserveData memory reserveData = AaveLendingPoolV2(AaveConstantsEthereum.AAVE_LENDING_POOL_V2).getReserveData(
            data_.asset
        );
        uint256 aTokenBalance = ERC20(reserveData.aTokenAddress).balanceOf(address(this));

        if (aTokenBalance < amountToWithdraw) {
            amountToWithdraw = aTokenBalance;
        }

        if (amountToWithdraw == 0) {
            // @dev Return original requested amount when balance is insufficient to maintain consistency
            //      with the caller's expectations and allow proper handling of partial withdrawals
            return (data_.asset, data_.amount);
        }

        return _performWithdraw(data_.asset, amountToWithdraw, catchExceptions_);
    }

    /// @notice Performs the actual withdrawal from Aave V2 protocol
    /// @param asset_ The address of the asset to withdraw
    /// @param amountToWithdraw_ The amount to withdraw
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn (or requested amount if withdrawal failed and catchExceptions_ is true)
    function _performWithdraw(
        address asset_,
        uint256 amountToWithdraw_,
        bool catchExceptions_
    ) private returns (address asset, uint256 amount) {
        if (catchExceptions_) {
            try AAVE_POOL.withdraw(asset_, amountToWithdraw_, address(this)) returns (uint256 withdrawnAmount) {
                emit AaveV2SupplyFuseExit(VERSION, asset_, withdrawnAmount);
                return (asset_, withdrawnAmount);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit AaveV2SupplyFuseExitFailed(VERSION, asset_, amountToWithdraw_);
                return (asset_, amountToWithdraw_);
            }
        } else {
            uint256 withdrawnAmount = AAVE_POOL.withdraw(asset_, amountToWithdraw_, address(this));
            emit AaveV2SupplyFuseExit(VERSION, asset_, withdrawnAmount);
            return (asset_, withdrawnAmount);
        }
    }
}
