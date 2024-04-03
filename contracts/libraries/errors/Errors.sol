// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

library Errors {
    string public constant NOT_SUPPORTED_TOKEN = "IPF_001";
    string public constant NOT_SUPPORTED_ERC4626 = "IPF_002";
    string public constant EMPTY_ARRAY_NOT_SUPPORTED = "IPF_003";
    string public constant ARRAY_LENGTH_MISMATCH = "IPF_004";
    string public constant UNSUPPORTED_ASSET = "IPF_005";
    string public constant ZERO_ADDRESS_NOT_SUPPORTED = "IPF_006";
}
