// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerFuseLib} from "./EulerFuseLib.sol";

import {IFuseCommon} from "../IFuseCommon.sol";

/// @notice Data structure for entering the Euler V2 Controller Fuse
/// @param eulerVault The address of the Euler vault
/// @param subAccount The sub-account identifier
struct EulerV2ControllerFuseEnterData {
    address eulerVault;
    bytes1 subAccount;
}

/// @notice Data structure for exiting the Euler V2 Controller Fuse
/// @param eulerVault The address of the Euler vault
/// @param subAccount The sub-account identifier
struct EulerV2ControllerFuseExitData {
    address eulerVault;
    bytes1 subAccount;
}

/// @title EulerV2ControllerFuse
/// @dev Fuse for Euler V2 vaults responsible for managing controllers in Euler V2 vaults
contract EulerV2ControllerFuse is IFuseCommon {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    IEVC public immutable EVC;

    error EulerV2ControllerFuseUnsupportedEnterAction(address vault, bytes1 subAccount);

    event EulerV2EnableControllerFuse(address version, address eulerVault, address subAccount);
    event EulerV2DisableControllerFuse(address version, address eulerVault, address subAccount);

    constructor(uint256 marketId_, address eulerV2EVC_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        EVC = IEVC(eulerV2EVC_);
    }

    /// @notice Enters the Euler V2 Controller Fuse with the specified parameters, enabling controlling collateral on Plasma Vault subAccount by EulerVault
    /// @param data_ The data structure containing the parameters for entering the Euler V2 Controller Fuse
    function enter(EulerV2ControllerFuseEnterData memory data_) external {
        if (!EulerFuseLib.canBorrow(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2ControllerFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        /* solhint-disable avoid-low-level-calls */
        EVC.enableController(subAccount, data_.eulerVault);
        /* solhint-enable avoid-low-level-calls */

        emit EulerV2EnableControllerFuse(VERSION, data_.eulerVault, subAccount);
    }

    /// @notice Exits the Euler V2 Controller Fuse with the specified parameters
    /// @param data_ The data structure containing the parameters for exiting the Euler V2 Controller Fuse
    function exit(EulerV2ControllerFuseExitData memory data_) external {
        /// @dev This is a safety check to ensure that the vault is supported by the fuse
        if (!EulerFuseLib.canSupply(MARKET_ID, data_.eulerVault, data_.subAccount)) {
            revert EulerV2ControllerFuseUnsupportedEnterAction(data_.eulerVault, data_.subAccount);
        }

        address subAccount = EulerFuseLib.generateSubAccountAddress(address(this), data_.subAccount);

        bytes memory disableController = abi.encodeWithSignature("disableController()");

        // The following call initiates a chain of interactions:
        // 1. Plasma Vault calls this EulerV2ControllerFuse contract
        // 2. This contract calls EVC.call
        // 3. EVC calls disableController on the EulerVault
        // 4. EulerVault calls disableController on the EVC
        // This process ensures the controller is properly disabled for the subAccount
        /* solhint-disable avoid-low-level-calls */
        EVC.call(data_.eulerVault, subAccount, 0, disableController);
        /* solhint-enable avoid-low-level-calls */

        emit EulerV2DisableControllerFuse(VERSION, data_.eulerVault, subAccount);
    }
}
