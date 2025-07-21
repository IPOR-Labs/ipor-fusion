// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

enum AerodromeSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct AerodromeSubstrate {
    AerodromeSubstrateType substrateType;
    address substrateAddress;
}

library AerodromeSubstrateLib {
    function substrateToBytes32(AerodromeSubstrate memory substrate) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate.substrateAddress)) | (uint256(substrate.substrateType) << 160));
    }

    function bytes32ToSubstrate(bytes32 bytes32Substrate) internal pure returns (AerodromeSubstrate memory substrate) {
        substrate.substrateType = AerodromeSubstrateType(uint256(bytes32Substrate) >> 160);
        substrate.substrateAddress = address(uint160(uint256(bytes32Substrate)));
    }
}
