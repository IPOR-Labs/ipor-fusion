// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data structure for entering - supply - the ERC4626 vault
struct Erc4626SupplyFuseEnterData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to supply, this is amount of underlying asset in the given ERC4626 vault
    uint256 vaultAssetAmount;
}

/// @notice Data structure for exiting - withdrawing - the ERC4626 vault
struct Erc4626SupplyFuseExitData {
    /// @dev ERC4626 vault address
    address vault;
    /// @dev amount to withdraw, this is amount of underlying asset in the given ERC4626 vault
    uint256 vaultAssetAmount;
}

/// @title Generic fuse for ERC4626 vaults responsible for supplying and withdrawing assets from the ERC4626 vaults based on preconfigured market substrates
/// @dev Substrates in this fuse are the assets that are used in the ERC4626 vaults for a given MARKET_ID
contract Erc4626SupplyFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeCast for uint256;
    using SafeERC20 for ERC20;

    /// @notice Emitted when assets are successfully deposited into an ERC4626 vault
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset being deposited
    /// @param vault The address of the ERC4626 vault receiving the deposit
    /// @param vaultAssetAmount The amount of underlying assets deposited into the vault
    event Erc4626SupplyFuseEnter(address version, address asset, address vault, uint256 vaultAssetAmount);

    /// @notice Emitted when assets are successfully withdrawn from an ERC4626 vault
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset being withdrawn
    /// @param vault The address of the ERC4626 vault from which assets are withdrawn
    /// @param vaultAssetAmount The amount of underlying assets withdrawn from the vault
    /// @param shares The amount of vault shares redeemed for the withdrawal
    event Erc4626SupplyFuseExit(
        address version,
        address asset,
        address vault,
        uint256 vaultAssetAmount,
        uint256 shares
    );

    /// @notice Emitted when withdrawal from an ERC4626 vault fails (used in instant withdraw scenarios)
    /// @param version The address of this fuse contract version
    /// @param asset The address of the underlying asset that failed to withdraw
    /// @param vault The address of the ERC4626 vault from which withdrawal was attempted
    /// @param vaultAssetAmount The amount of underlying assets that failed to withdraw
    event Erc4626SupplyFuseExitFailed(address version, address asset, address vault, uint256 vaultAssetAmount);

    error Erc4626SupplyFuseUnsupportedVault(string action, address asset);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(Erc4626SupplyFuseEnterData memory data_) public returns (uint256 finalVaultAssetAmount) {
        if (data_.vaultAssetAmount == 0) {
            return 0;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("enter", data_.vault);
        }

        address underlyingAsset = IERC4626(data_.vault).asset();

        finalVaultAssetAmount = IporMath.min(
            data_.vaultAssetAmount,
            IERC4626(underlyingAsset).balanceOf(address(this))
        );

        if (finalVaultAssetAmount == 0) {
            return 0;
        }

        ERC20(underlyingAsset).forceApprove(data_.vault, finalVaultAssetAmount);

        IERC4626(data_.vault).deposit(finalVaultAssetAmount, address(this));

        emit Erc4626SupplyFuseEnter(VERSION, underlyingAsset, data_.vault, finalVaultAssetAmount);
    }

    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address vault = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        uint256 suppliedAmount = enter(Erc4626SupplyFuseEnterData({vault: vault, vaultAssetAmount: amount}));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(suppliedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function exit(Erc4626SupplyFuseExitData memory data_) public returns (uint256 shares) {
        return _exit({data_: data_, catchExceptions_: false});
    }

    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address vault = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        uint256 shares = exit(Erc4626SupplyFuseExitData({vault: vault, vaultAssetAmount: amount}));

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(shares);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @dev params[0] - amount in underlying asset, params[1] - vault address
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        address vault = PlasmaVaultConfigLib.bytes32ToAddress(params_[1]);

        _exit(Erc4626SupplyFuseExitData(vault, amount), true);
    }

    function _exit(Erc4626SupplyFuseExitData memory data_, bool catchExceptions_) internal returns (uint256 shares) {
        if (data_.vaultAssetAmount == 0) {
            return 0;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.vault)) {
            revert Erc4626SupplyFuseUnsupportedVault("exit", data_.vault);
        }

        uint256 finalVaultAssetAmount = IporMath.min(
            data_.vaultAssetAmount,
            IERC4626(data_.vault).maxWithdraw(address(this))
        );

        if (finalVaultAssetAmount == 0) {
            return 0;
        }

        return _performWithdraw(data_.vault, finalVaultAssetAmount, catchExceptions_);
    }

    function _performWithdraw(
        address vault_,
        uint256 finalVaultAssetAmount_,
        bool catchExceptions_
    ) private returns (uint256 shares) {
        if (catchExceptions_) {
            try IERC4626(vault_).withdraw(finalVaultAssetAmount_, address(this), address(this)) returns (
                uint256 shares_
            ) {
                shares = shares_;
                emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_, shares);
            } catch {
                /// @dev if withdraw failed, continue with the next step
                emit Erc4626SupplyFuseExitFailed(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_);
            }
        } else {
            shares = IERC4626(vault_).withdraw(finalVaultAssetAmount_, address(this), address(this));
            emit Erc4626SupplyFuseExit(VERSION, IERC4626(vault_).asset(), vault_, finalVaultAssetAmount_, shares);
        }
    }
}
