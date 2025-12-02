// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
}

error PlasmaVaultRedeemFromRequestFuseUnsupportedVault(string action, address vault);
error PlasmaVaultRedeemFromRequestFuseInvalidWithdrawManager(address vault);

/// @title Fuse for Plasma Vault responsible for redeeming shares from request
/// @dev This fuse is used to redeem shares from a previously submitted withdrawal request
contract PlasmaVaultRedeemFromRequestFuse is IFuseCommon {
    event PlasmaVaultRedeemFromRequestFuseEnter(address version, address plasmaVault, uint256 sharesAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Enters the Fuse - redeems shares from request
    /// @param data_ Data structure containing shares amount and plasma vault address
    /// @return plasmaVault Address of the Plasma Vault
    /// @return sharesAmount Final amount of shares redeemed
    function enter(
        PlasmaVaultRedeemFromRequestFuseEnterData memory data_
    ) public returns (address plasmaVault, uint256 sharesAmount) {
        if (data_.sharesAmount == 0) {
            return (data_.plasmaVault, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.plasmaVault)) {
            revert PlasmaVaultRedeemFromRequestFuseUnsupportedVault("enter", data_.plasmaVault);
        }

        uint256 balance = IERC20(data_.plasmaVault).balanceOf(address(this));

        uint256 finalSharesAmount = balance < data_.sharesAmount ? balance : data_.sharesAmount;

        if (finalSharesAmount == 0) {
            return (data_.plasmaVault, 0);
        }

        IPlasmaVault(data_.plasmaVault).redeemFromRequest(finalSharesAmount, address(this), address(this));

        plasmaVault = data_.plasmaVault;
        sharesAmount = finalSharesAmount;

        emit PlasmaVaultRedeemFromRequestFuseEnter(VERSION, plasmaVault, sharesAmount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        uint256 sharesAmount_ = TypeConversionLib.toUint256(inputs[0]);
        address plasmaVault_ = TypeConversionLib.toAddress(inputs[1]);

        (address plasmaVault, uint256 sharesAmount) = enter(
            PlasmaVaultRedeemFromRequestFuseEnterData(sharesAmount_, plasmaVault_)
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(plasmaVault);
        outputs[1] = TypeConversionLib.toBytes32(sharesAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
