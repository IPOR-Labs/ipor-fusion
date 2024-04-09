// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

library Errors {
    string public constant UNSUPPORTED_ASSET = "IPF_001";
    string public constant UNSUPPORTED_ERC4626 = "IPF_002";
    string public constant UNSUPPORTED_EMPTY_ARRAY = "IPF_003";
    string public constant UNSUPPORTED_ZERO_ADDRESS = "IPF_004";
    string public constant ARRAY_LENGTH_MISMATCH = "IPF_005";
    string public constant UNSUPPORTED_MARKET = "IPF_006";
}
