// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";

/// @dev Struct for setting inputs in transient storage
struct TransientStorageSetInputsFuseEnterData {
    /// @notice The addresses of the fuses for which inputs are being set
    address[] fuse;
    /// @notice The input data to be stored
    bytes32[][] inputsByFuse;
}

/// @title TransientStorageSetInputsFuse
/// @notice Fuse for setting initial data in transient storage for other fuses
/// @author IPOR Labs
contract TransientStorageSetInputsFuse is IFuseCommon {
    /// @notice The market ID associated with the Fuse
    uint256 public constant MARKET_ID = IporFusionMarkets.ERC20_VAULT_BALANCE;

    error WrongFuseAddress();
    error WrongInputsLength();

    /// @notice Sets the inputs for specific fuses in transient storage
    /// @param data_ The data containing the fuse addresses and inputs
    /// @dev Reverts with WrongInputsLength if array lengths don't match or if any inputsByFuse element is empty
    /// @dev Reverts with WrongFuseAddress if any fuse address is zero
    function enter(TransientStorageSetInputsFuseEnterData calldata data_) external {
        uint256 len = data_.fuse.length;

        // Validate array lengths match to prevent out-of-bounds panic
        if (data_.inputsByFuse.length != len) {
            revert WrongInputsLength();
        }

        for (uint256 i; i < len; ++i) {
            if (data_.fuse[i] == address(0)) {
                revert WrongFuseAddress();
            }
            if (data_.inputsByFuse[i].length == 0) {
                revert WrongInputsLength();
            }
            TransientStorageLib.setInputs(data_.fuse[i], data_.inputsByFuse[i]);
        }
    }
}
