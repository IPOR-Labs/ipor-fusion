// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../../../contracts/transient_storage/TransientStorageLib.sol";

/// @title EulerV2SwapTestVault
/// @notice Minimal PlasmaVault-like harness used by EulerSwap unit tests.
/// @dev Stores substrates in the canonical storage slots (via {PlasmaVaultConfigLib}) and forwards
///      fuse calls via delegatecall, so inside the fuse `address(this)` == this harness and the
///      substrate storage is read from this harness. Mirrors {MockPlasmaVaultForRWA}.
contract EulerV2SwapTestVault {
    /// @notice Grant substrates to a market (overwriting any previous grants).
    function grantMarketSubstrates(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    /// @notice Grant substrates as assets to a market.
    function grantSubstratesAsAssetsToMarket(uint256 marketId_, address[] calldata substrates_) external {
        PlasmaVaultConfigLib.grantSubstratesAsAssetsToMarket(marketId_, substrates_);
    }

    /// @notice Forward `data_` to `target_` via delegatecall, bubbling reverts.
    function delegateExecute(address target_, bytes calldata data_) external payable returns (bytes memory) {
        (bool ok, bytes memory ret) = target_.delegatecall(data_);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
        return ret;
    }

    /// @notice Write `inputs_` into this harness's transient storage keyed by `version_` (the fuse address).
    /// @dev Must be called within the same transaction as the delegatecall that reads them, since the fuse
    ///      reads `getInputs(VERSION)` from the caller's (this harness's) transient storage.
    function setTransientInputs(address version_, bytes32[] memory inputs_) external {
        TransientStorageLib.setInputs(version_, inputs_);
    }

    /// @notice Read transient outputs keyed by `version_` (the fuse address) from this harness's storage.
    function getTransientOutputs(address version_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getOutputs(version_);
    }

    receive() external payable {}
}
