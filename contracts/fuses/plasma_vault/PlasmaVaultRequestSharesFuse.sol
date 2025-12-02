// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {UniversalReader, ReadResult} from "../../universal_reader/UniversalReader.sol";
import {WithdrawManager} from "../../managers/withdraw/WithdrawManager.sol";
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

    /// @notice Requests shares from the Plasma Vault
    /// @param data_ The data structure containing plasma vault address and shares amount
    /// @return plasmaVault The address of the Plasma Vault
    /// @return sharesAmount The amount of shares requested
    function enter(
        PlasmaVaultRequestSharesFuseEnterData memory data_
    ) public returns (address plasmaVault, uint256 sharesAmount) {
        if (data_.sharesAmount == 0) {
            return (data_.plasmaVault, 0);
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.plasmaVault)) {
            revert PlasmaVaultRequestSharesFuseUnsupportedVault("enter", data_.plasmaVault);
        }

        uint256 balance = IERC20(data_.plasmaVault).balanceOf(address(this));

        uint256 finalSharesAmount = balance < data_.sharesAmount ? balance : data_.sharesAmount;

        if (finalSharesAmount == 0) {
            return (data_.plasmaVault, 0);
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

        plasmaVault = data_.plasmaVault;
        sharesAmount = data_.sharesAmount;

        emit PlasmaVaultRequestSharesFuseEnter(VERSION, plasmaVault, sharesAmount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        uint256 sharesAmount = TypeConversionLib.toUint256(inputs[0]);
        address plasmaVault = TypeConversionLib.toAddress(inputs[1]);

        (address returnedPlasmaVault, uint256 returnedSharesAmount) = enter(
            PlasmaVaultRequestSharesFuseEnterData({sharesAmount: sharesAmount, plasmaVault: plasmaVault})
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedPlasmaVault);
        outputs[1] = TypeConversionLib.toBytes32(returnedSharesAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    function getWithdrawManager() external view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManager().manager;
    }
}
