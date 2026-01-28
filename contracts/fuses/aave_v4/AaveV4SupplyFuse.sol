// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IporMath} from "../../libraries/math/IporMath.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {AaveV4SubstrateLib} from "./AaveV4SubstrateLib.sol";
import {IAaveV4Spoke} from "./ext/IAaveV4Spoke.sol";

/// @dev Data structure for entering (supply) the Aave V4 protocol
struct AaveV4SupplyFuseEnterData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to supply
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to supply
    uint256 amount;
    /// @notice Minimum amount of supply shares expected to receive
    uint256 minShares;
}

/// @dev Data structure for exiting (withdraw) from the Aave V4 protocol
struct AaveV4SupplyFuseExitData {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice ERC20 token address to withdraw
    address asset;
    /// @notice Aave V4 reserve identifier within the Spoke
    uint256 reserveId;
    /// @notice Amount of tokens to withdraw
    uint256 amount;
    /// @notice Minimum amount of tokens expected to withdraw
    uint256 minAmount;
}

/// @title AaveV4SupplyFuse
/// @author IPOR Labs
/// @notice Fuse for Aave V4 protocol responsible for supplying and withdrawing assets via Spoke contracts
/// @dev Executes in PlasmaVault storage context via delegatecall. MUST NOT contain storage variables.
///      Substrates are validated as both Asset and Spoke types using AaveV4SubstrateLib encoding.
contract AaveV4SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for ERC20;

    /// @notice The address of the version of the Fuse
    address public immutable VERSION;
    /// @notice The Market ID associated with the Fuse
    uint256 public immutable MARKET_ID;

    /// @notice Emitted when entering the Aave V4 supply fuse
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset supplied
    /// @param reserveId The reserve identifier
    /// @param shares The amount of supply shares received
    event AaveV4SupplyFuseEnter(address version, address spoke, address asset, uint256 reserveId, uint256 shares);

    /// @notice Emitted when exiting the Aave V4 supply fuse
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset withdrawn
    /// @param reserveId The reserve identifier
    /// @param amount The amount of the asset withdrawn
    event AaveV4SupplyFuseExit(address version, address spoke, address asset, uint256 reserveId, uint256 amount);

    /// @notice Emitted when exiting the Aave V4 supply fuse fails during instant withdraw
    /// @param version The address of the fuse version
    /// @param spoke The Aave V4 Spoke contract address
    /// @param asset The address of the asset
    /// @param reserveId The reserve identifier
    /// @param amount The amount that was attempted to withdraw
    event AaveV4SupplyFuseExitFailed(
        address version,
        address spoke,
        address asset,
        uint256 reserveId,
        uint256 amount
    );

    /// @notice Thrown when market ID is zero or invalid
    /// @custom:error AaveV4SupplyFuseInvalidMarketId
    error AaveV4SupplyFuseInvalidMarketId();

    /// @notice Thrown when received shares are below the minimum required
    /// @param receivedShares The amount of shares actually received
    /// @param minShares The minimum amount of shares required
    /// @custom:error AaveV4SupplyFuseInsufficientShares
    error AaveV4SupplyFuseInsufficientShares(uint256 receivedShares, uint256 minShares);

    /// @notice Thrown when withdrawn amount is below the minimum required
    /// @param withdrawnAmount The amount actually withdrawn
    /// @param minAmount The minimum amount required
    /// @custom:error AaveV4SupplyFuseInsufficientAmount
    error AaveV4SupplyFuseInsufficientAmount(uint256 withdrawnAmount, uint256 minAmount);

    /// @notice Thrown when a substrate (asset or spoke) is not authorized for this market
    /// @param action The action being performed ("enter" or "exit")
    /// @param substrate The unauthorized substrate bytes32 value
    error AaveV4SupplyFuseUnsupportedSubstrate(string action, bytes32 substrate);

    /// @notice Constructor for AaveV4SupplyFuse
    /// @param marketId_ The Market ID associated with the Fuse
    constructor(uint256 marketId_) {
        if (marketId_ == 0) {
            revert AaveV4SupplyFuseInvalidMarketId();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters (supplies) assets to Aave V4 protocol via a Spoke contract
    /// @param data_ Enter data containing spoke, asset, reserveId, amount, and minShares
    /// @return asset The address of the supplied asset
    /// @return amount The amount of assets supplied
    /// @custom:revert AaveV4SupplyFuseInsufficientShares When received shares are below minShares
    function enter(AaveV4SupplyFuseEnterData memory data_) public returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        _validateSubstrates("enter", data_.asset, data_.spoke);

        uint256 finalAmount = IporMath.min(ERC20(data_.asset).balanceOf(address(this)), data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        ERC20(data_.asset).forceApprove(data_.spoke, finalAmount);

        (uint256 shares, ) = IAaveV4Spoke(data_.spoke).supply(data_.reserveId, finalAmount, address(this));

        if (shares < data_.minShares) {
            revert AaveV4SupplyFuseInsufficientShares(shares, data_.minShares);
        }

        emit AaveV4SupplyFuseEnter(VERSION, data_.spoke, data_.asset, data_.reserveId, shares);

        return (data_.asset, finalAmount);
    }

    /// @notice Enters (supplies) assets to Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minShares (4) from transient storage
    function enterTransient() external {
        bytes32 spokeBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 reserveIdBytes32 = TransientStorageLib.getInput(VERSION, 2);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 3);
        bytes32 minSharesBytes32 = TransientStorageLib.getInput(VERSION, 4);

        AaveV4SupplyFuseEnterData memory data = AaveV4SupplyFuseEnterData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(spokeBytes32),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32),
            reserveId: TypeConversionLib.toUint256(reserveIdBytes32),
            amount: TypeConversionLib.toUint256(amountBytes32),
            minShares: TypeConversionLib.toUint256(minSharesBytes32)
        });

        (address returnedAsset, uint256 returnedAmount) = enter(data);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits (withdraws) assets from Aave V4 protocol via a Spoke contract
    /// @param data_ Exit data containing spoke, asset, reserveId, amount, and minAmount
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    /// @custom:revert AaveV4SupplyFuseInsufficientAmount When withdrawn amount is below minAmount
    function exit(AaveV4SupplyFuseExitData calldata data_) public returns (address asset, uint256 amount) {
        return _exit(data_, false);
    }

    /// @notice Exits (withdraws) assets from Aave V4 protocol using transient storage for inputs
    /// @dev Reads spoke (0), asset (1), reserveId (2), amount (3), minAmount (4) from transient storage
    function exitTransient() external {
        bytes32 spokeBytes32 = TransientStorageLib.getInput(VERSION, 0);
        bytes32 assetBytes32 = TransientStorageLib.getInput(VERSION, 1);
        bytes32 reserveIdBytes32 = TransientStorageLib.getInput(VERSION, 2);
        bytes32 amountBytes32 = TransientStorageLib.getInput(VERSION, 3);
        bytes32 minAmountBytes32 = TransientStorageLib.getInput(VERSION, 4);

        AaveV4SupplyFuseExitData memory data = AaveV4SupplyFuseExitData({
            spoke: PlasmaVaultConfigLib.bytes32ToAddress(spokeBytes32),
            asset: PlasmaVaultConfigLib.bytes32ToAddress(assetBytes32),
            reserveId: TypeConversionLib.toUint256(reserveIdBytes32),
            amount: TypeConversionLib.toUint256(amountBytes32),
            minAmount: TypeConversionLib.toUint256(minAmountBytes32)
        });

        (address returnedAsset, uint256 returnedAmount) = _exit(data, false);

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedAsset);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Performs instant withdrawal from Aave V4 protocol with exception handling
    /// @param params_ Array of parameters: [0] amount, [1] asset address, [2] spoke address, [3] reserveId, [4] minAmount
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);
        address asset = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);
        address spoke = PlasmaVaultConfigLib.bytes32ToAddress(params_[2]);
        uint256 reserveId = uint256(params_[3]);
        uint256 minAmount = uint256(params_[4]);

        _exit(
            AaveV4SupplyFuseExitData({
                spoke: spoke,
                asset: asset,
                reserveId: reserveId,
                amount: amount,
                minAmount: minAmount
            }),
            true
        );
    }

    /// @notice Internal function to exit (withdraw) assets from Aave V4 protocol
    /// @param data_ Exit data containing spoke, asset, reserveId, and amount
    /// @param catchExceptions_ Whether to catch exceptions during withdrawal
    /// @return asset The address of the withdrawn asset
    /// @return amount The amount of assets withdrawn
    function _exit(
        AaveV4SupplyFuseExitData memory data_,
        bool catchExceptions_
    ) internal returns (address asset, uint256 amount) {
        if (data_.amount == 0) {
            return (data_.asset, 0);
        }

        _validateSubstrates("exit", data_.asset, data_.spoke);

        uint256 supplyAssets = IAaveV4Spoke(data_.spoke).getUserSuppliedAssets(data_.reserveId, address(this));

        if (supplyAssets == 0) {
            return (data_.asset, 0);
        }

        uint256 finalAmount = IporMath.min(supplyAssets, data_.amount);

        if (finalAmount == 0) {
            return (data_.asset, 0);
        }

        if (catchExceptions_) {
            try IAaveV4Spoke(data_.spoke).withdraw(data_.reserveId, finalAmount, address(this)) returns (
                uint256,
                uint256 withdrawnAmount
            ) {
                if (withdrawnAmount < data_.minAmount) {
                    revert AaveV4SupplyFuseInsufficientAmount(withdrawnAmount, data_.minAmount);
                }
                emit AaveV4SupplyFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, withdrawnAmount);
                return (data_.asset, withdrawnAmount);
            } catch {
                emit AaveV4SupplyFuseExitFailed(VERSION, data_.spoke, data_.asset, data_.reserveId, finalAmount);
                return (data_.asset, 0);
            }
        } else {
            (, uint256 withdrawnAmount) = IAaveV4Spoke(data_.spoke).withdraw(data_.reserveId, finalAmount, address(this));
            if (withdrawnAmount < data_.minAmount) {
                revert AaveV4SupplyFuseInsufficientAmount(withdrawnAmount, data_.minAmount);
            }
            emit AaveV4SupplyFuseExit(VERSION, data_.spoke, data_.asset, data_.reserveId, withdrawnAmount);
            return (data_.asset, withdrawnAmount);
        }
    }

    /// @notice Validates that both asset and spoke substrates are granted for this market
    /// @param action_ The action being performed (for error message)
    /// @param asset_ The asset address to validate
    /// @param spoke_ The spoke address to validate
    function _validateSubstrates(string memory action_, address asset_, address spoke_) internal view {
        bytes32 assetSubstrate = AaveV4SubstrateLib.encodeAsset(asset_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, assetSubstrate)) {
            revert AaveV4SupplyFuseUnsupportedSubstrate(action_, assetSubstrate);
        }

        bytes32 spokeSubstrate = AaveV4SubstrateLib.encodeSpoke(spoke_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, spokeSubstrate)) {
            revert AaveV4SupplyFuseUnsupportedSubstrate(action_, spokeSubstrate);
        }
    }
}
