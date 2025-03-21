// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {UniversalReader, ReadResult} from "../../universal_reader/UniversalReader.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
/// @notice Data structure for entering - requesting shares - the Plasma Vault
struct PlasmaVaultRequestSharesFuseEnterData {
    /// @dev amount of shares to request
    uint256 sharesAmount;
    /// @dev address of the Plasma Vault
    address plasmaVault;
}

error PlasmaVaultRequestSharesFuseUnsupportedVault(string action, address vault);
error PlasmaVaultRequestSharesFuseInvalidWithdrawManager(address vault);
/// @title Fuse for Plasma Vault responsible for requesting and withdrawing shares
/// @dev This fuse is used to manage share requests and withdrawals in the Plasma Vault
contract PlasmaVaultRequestSharesFuse is IFuseCommon {
    event PlasmaVaultRequestSharesFuseEnter(address version, address plasmaVault, uint256 sharesAmount);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(PlasmaVaultRequestSharesFuseEnterData memory data_) external {
        if (data_.sharesAmount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.plasmaVault)) {
            revert PlasmaVaultRequestSharesFuseUnsupportedVault("enter", data_.plasmaVault);
        }

        uint256 balance = IERC20(data_.plasmaVault).balanceOf(address(this));

        uint256 finalSharesAmount = balance < data_.sharesAmount ? balance : data_.sharesAmount;

        if (finalSharesAmount == 0) {
            return;
        }

        ReadResult memory readResult = UniversalReader(data_.plasmaVault).read(
            VERSION,
            abi.encodeWithSignature("getWithdrawManager()")
        );
        address withdrawManager = abi.decode(readResult.data, (address));

        if (withdrawManager == address(0)) {
            revert PlasmaVaultRequestSharesFuseInvalidWithdrawManager(data_.plasmaVault);
        }

        WithdrawManager(withdrawManager).requestShares(finalSharesAmount);

        emit PlasmaVaultRequestSharesFuseEnter(VERSION, data_.plasmaVault, data_.sharesAmount);
    }

    function getWithdrawManager() external view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManager().manager;
    }
}
