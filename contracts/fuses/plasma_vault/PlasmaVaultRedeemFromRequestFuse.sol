// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/// @notice Data structure for entering - redeeming from request - the Plasma Vault
struct PlasmaVaultRedeemFromRequestFuseEnterData {
    /// @dev amount of shares to redeem
    uint256 sharesAmount;
    /// @dev address of the Plasma Vault
    address plasmaVault;
    /// @dev minimum amount of underlying assets the calling Plasma Vault must receive from the redeem, 0 means no
    ///      minimum. It is compared with the measured change of the caller's balance of the target vault's `asset()`,
    ///      not with the value returned by `redeemFromRequest`. The minimum is absolute for the call: when the fuse
    ///      clips the redeemed shares to the held balance, a minimum sized for the larger amount reverts. It is not
    ///      checked when there is nothing to redeem (zero shares requested or zero balance held).
    uint256 minAssetsOut;
}

error PlasmaVaultRedeemFromRequestFuseUnsupportedVault(string action, address vault);

/// @notice Thrown when the assets received from the redeem are below the minimum required
/// @param receivedAssets The amount of underlying assets actually received
/// @param minAssetsOut The minimum amount of underlying assets required
error PlasmaVaultRedeemFromRequestFuseInsufficientAssets(uint256 receivedAssets, uint256 minAssetsOut);

/// @title Fuse for Plasma Vault responsible for redeeming shares from request
/// @dev This fuse is used to redeem shares from a previously submitted withdrawal request. Since IL-9622 the enter data
///      has a third field, `minAssetsOut`: `enter((uint256,address,uint256))` (selector 0x764e8db7) replaces the earlier
///      `enter((uint256,address))`, and a shortfall reverts with
///      `PlasmaVaultRedeemFromRequestFuseInsufficientAssets(uint256,uint256)` (selector 0x97a5a00a). `enterTransient`
///      reads three inputs: `[sharesAmount, plasmaVault, minAssetsOut]`.
contract PlasmaVaultRedeemFromRequestFuse is IFuseCommon {
    event PlasmaVaultRedeemFromRequestFuseEnter(address version, address plasmaVault, uint256 sharesAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the Fuse - redeems shares from request
    /// @dev This function redeems shares from a previously submitted withdrawal request. The balance comparison
    ///      logic ensures that we only attempt to redeem shares that are actually available. When a withdrawal
    ///      request is made via PlasmaVaultRequestSharesFuse, the vault receives plasma vault tokens representing
    ///      the requested shares. This function checks the vault's current balance of these tokens and limits the
    ///      redemption to the minimum of: (1) the requested shares amount, or (2) the actual balance available.
    ///      This prevents attempting to redeem more shares than have been requested and are available for redemption.
    ///      When `minAssetsOut` is greater than 0, the change of the caller's balance of the target vault's `asset()`
    ///      around `redeemFromRequest` is measured (the returned value is not trusted) and a shortfall reverts. With
    ///      `minAssetsOut == 0` no extra balance read is made.
    /// @param data_ Data structure containing shares amount, plasma vault address and minimum assets out
    /// @return plasmaVault Address of the Plasma Vault
    /// @return sharesAmount Final amount of shares redeemed (may be less than requested if balance is insufficient)
    function enter(
        PlasmaVaultRedeemFromRequestFuseEnterData memory data_
    ) public returns (address plasmaVault, uint256 sharesAmount) {
        if (data_.sharesAmount == 0) {
            return (data_.plasmaVault, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.plasmaVault)) {
            revert PlasmaVaultRedeemFromRequestFuseUnsupportedVault("enter", data_.plasmaVault);
        }

        // Get the vault's current balance of plasma vault tokens (shares available for redemption)
        // These tokens represent shares that were previously requested via PlasmaVaultRequestSharesFuse
        uint256 balance = IERC20(data_.plasmaVault).balanceOf(address(this));

        // Use the minimum of requested amount and available balance to prevent over-redemption
        // This ensures we only redeem shares that are actually available from previous withdrawal requests
        uint256 finalSharesAmount = balance < data_.sharesAmount ? balance : data_.sharesAmount;

        if (finalSharesAmount == 0) {
            return (data_.plasmaVault, 0);
        }

        address underlying;
        uint256 balanceBefore;
        if (data_.minAssetsOut > 0) {
            underlying = IERC4626(data_.plasmaVault).asset();
            balanceBefore = IERC20(underlying).balanceOf(address(this));
        }

        IPlasmaVault(data_.plasmaVault).redeemFromRequest(finalSharesAmount, address(this), address(this));

        if (data_.minAssetsOut > 0) {
            uint256 received = IERC20(underlying).balanceOf(address(this)) - balanceBefore;
            if (received < data_.minAssetsOut) {
                revert PlasmaVaultRedeemFromRequestFuseInsufficientAssets(received, data_.minAssetsOut);
            }
        }

        plasmaVault = data_.plasmaVault;
        sharesAmount = finalSharesAmount;

        emit PlasmaVaultRedeemFromRequestFuseEnter(VERSION, plasmaVault, sharesAmount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 sharesAmount_ = TypeConversionLib.toUint256(inputs[0]);
        address plasmaVault_ = TypeConversionLib.toAddress(inputs[1]);
        uint256 minAssetsOut_ = TypeConversionLib.toUint256(inputs[2]);

        (address plasmaVault, uint256 sharesAmount) = enter(
            PlasmaVaultRedeemFromRequestFuseEnterData(sharesAmount_, plasmaVault_, minAssetsOut_)
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(plasmaVault);
        outputs[1] = TypeConversionLib.toBytes32(sharesAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
