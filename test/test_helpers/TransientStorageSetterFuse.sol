// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {TransientStorageLib} from "../../contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../contracts/libraries/TypeConversionLib.sol";

contract TransientStorageSetterFuse {
    error OutputMismatch(uint256 index, bytes32 expected, bytes32 actual);
    error OutputLengthMismatch(uint256 expected, uint256 actual);

    uint256 public constant MARKET_ID = 0;

    function setInputs(address account_, bytes32[] calldata inputs_) external {
        TransientStorageLib.setInputs(account_, inputs_);
    }

    function checkOutputs(address account_, bytes32[] calldata expectedOutputs_) external view {
        bytes32[] memory actualOutputs = TransientStorageLib.getOutputs(account_);

        if (actualOutputs.length != expectedOutputs_.length) {
            revert OutputLengthMismatch(expectedOutputs_.length, actualOutputs.length);
        }

        for (uint256 i = 0; i < expectedOutputs_.length; ++i) {
            if (actualOutputs[i] != expectedOutputs_[i]) {
                revert OutputMismatch(i, expectedOutputs_[i], actualOutputs[i]);
            }
        }
    }

    function getOutputs(address account_) external view returns (bytes32[] memory) {
        return TransientStorageLib.getOutputs(account_);
    }
}
