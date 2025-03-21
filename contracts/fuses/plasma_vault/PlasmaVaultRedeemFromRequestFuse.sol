// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";

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

    function enter(PlasmaVaultRedeemFromRequestFuseEnterData memory data_) external {
        if (data_.sharesAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.plasmaVault)) {
            revert PlasmaVaultRedeemFromRequestFuseUnsupportedVault("enter", data_.plasmaVault);
        }

        uint256 balance = IERC20(data_.plasmaVault).balanceOf(address(this));

        uint256 finalSharesAmount = balance < data_.sharesAmount ? balance : data_.sharesAmount;

        if (finalSharesAmount == 0) {
            return;
        }

        IPlasmaVault(data_.plasmaVault).redeemFromRequest(finalSharesAmount, address(this), address(this));

        emit PlasmaVaultRedeemFromRequestFuseEnter(VERSION, data_.plasmaVault, finalSharesAmount);
    }
}
