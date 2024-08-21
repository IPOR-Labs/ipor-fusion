// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.22;

interface IPlasmaVaultBase {
    function init(string memory assetName_, address accessManager_) external;

    function updateInternal(address from_, address to_, uint256 value_) external;
}
