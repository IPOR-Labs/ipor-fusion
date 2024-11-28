// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";

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
    function enter(EulerV2CollateralFuseEnterData memory data_) external {
        if (!EulerFuseLib.canCollateral(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2CollateralFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        EVC.enableCollateral(subAccount, data_.eulerVault);

        emit EulerV2EnableCollateralFuse(VERSION, data_.eulerVault, subAccount);
    }
    /// @notice Exits the Euler V2 Collateral Fuse with the specified parameters, disabling collateral for the given vault and sub-account
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Collateral Fuse and disabling collateral
    function exit(EulerV2CollateralFuseExitData memory data_) external {
        address subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        EVC.disableCollateral(subAccount, data_.eulerVault);

        emit EulerV2DisableCollateralFuse(VERSION, data_.eulerVault, subAccount);
    }
}
