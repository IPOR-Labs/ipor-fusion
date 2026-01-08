// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

import {IFuseCommon} from "../IFuseCommon.sol";

/// @notice Data structure for entering the Euler V2 Collateral Fuse
/// @param eulerVault The address of the Euler vault
/// @param subAccount The sub-account identifier
struct EulerV2CollateralFuseEnterData {
    address eulerVault;
    bytes1 subAccount;
}

/// @notice Data structure for exiting the Euler V2 Collateral Fuse
/// @param eulerVault The address of the Euler vault
/// @param subAccount The sub-account identifier
struct EulerV2CollateralFuseExitData {
    address eulerVault;
    bytes1 subAccount;
}

/// @title EulerV2CollateralFuse
/// @dev Fuse for Euler V2 vaults responsible for managing collateral in Euler V2 vaults
contract EulerV2CollateralFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    error EulerV2CollateralFuseUnsupportedEnterAction(address vault, bytes1 subAccount);

    event EulerV2EnableCollateralFuse(address version, address eulerVault, address subAccount);
    event EulerV2DisableCollateralFuse(address version, address eulerVault, address subAccount);

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Collateral Fuse with the specified parameters, enabling collateral for the given vault and sub-account
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Collateral Fuse and enabling collateral
    /// @return eulerVault The address of the Euler vault
    /// @return subAccount The generated sub-account address
    function enter(
        EulerV2CollateralFuseEnterData memory data_
    ) public returns (address eulerVault, address subAccount) {
        if (!EulerFuseLib.canCollateral(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2CollateralFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);
        eulerVault = data_.eulerVault;

        EVC.enableCollateral(subAccount, eulerVault);

        emit EulerV2EnableCollateralFuse(VERSION, eulerVault, subAccount);
    }
    /// @notice Exits the Euler V2 Collateral Fuse with the specified parameters, disabling collateral for the given vault and sub-account
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Collateral Fuse and disabling collateral
    /// @return eulerVault The address of the Euler vault
    /// @return subAccount The generated sub-account address
    function exit(EulerV2CollateralFuseExitData memory data_) public returns (address eulerVault, address subAccount) {
        subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);
        eulerVault = data_.eulerVault;

        EVC.disableCollateral(subAccount, eulerVault);

        emit EulerV2DisableCollateralFuse(VERSION, eulerVault, subAccount);
    }

    /// @notice Enters the Euler V2 Collateral Fuse using transient storage for parameters
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address eulerVault = TypeConversionLib.toAddress(inputs[0]);
        bytes1 subAccount = bytes1(uint8(TypeConversionLib.toUint256(inputs[1])));

        (address returnedEulerVault, address returnedSubAccount) = enter(
            EulerV2CollateralFuseEnterData(eulerVault, subAccount)
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedEulerVault);
        outputs[1] = TypeConversionLib.toBytes32(returnedSubAccount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Euler V2 Collateral Fuse using transient storage for parameters
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address eulerVault = TypeConversionLib.toAddress(inputs[0]);
        bytes1 subAccount = bytes1(uint8(TypeConversionLib.toUint256(inputs[1])));

        (address returnedEulerVault, address returnedSubAccount) = exit(
            EulerV2CollateralFuseExitData(eulerVault, subAccount)
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedEulerVault);
        outputs[1] = TypeConversionLib.toBytes32(returnedSubAccount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
