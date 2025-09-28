// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultLib, InstantWithdrawalFusesParamsStruct} from "../../libraries/PlasmaVaultLib.sol";

error ExitNotSupported();

struct ConfigureInstantWithdrawalFuseEnterData {
    /// @dev Array of fuse configurations with their respective parameters
    InstantWithdrawalFusesParamsStruct[] fuses;
}

/// @title Configure Instant Withdrawal Fuse
/// @notice Fuse for configuring instant withdrawal settings
/// @dev This fuse provides empty enter and exit methods for configuration purposes
contract ConfigureInstantWithdrawalFuse is IFuseCommon {
    /// @notice Version of this contract for tracking
    address public immutable VERSION;

    /// @notice Market ID this fuse is associated with
    uint256 public immutable MARKET_ID;

    /// @notice Initializes the fuse with market ID
    /// @param marketId_ Market ID for this fuse
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    function enter(ConfigureInstantWithdrawalFuseEnterData calldata data_) external {
        // Validation is performed inside PlasmaVaultLib.configureInstantWithdrawalFuses:
        // - Validates that each fuse is supported
        // - Validates fuse parameters
        // - Validates array lengths and data integrity
        PlasmaVaultLib.configureInstantWithdrawalFuses(data_.fuses);
    }

    function exit(bytes calldata) external pure {
        // No exit functionality needed for this fuse
        revert ExitNotSupported();
    }
}
