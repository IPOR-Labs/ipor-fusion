// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

enum VelodromeSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct VelodromeSubstrate {
    VelodromeSubstrateType substrateType;
    address substrateAddress;
}

library VelodromeSubstrateLib {
    function substrateToBytes32(VelodromeSubstrate memory substrate) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate.substrateAddress)) | (uint256(substrate.substrateType) << 160));
    }

    function bytes32ToSubstrate(bytes32 bytes32Substrate) internal pure returns (VelodromeSubstrate memory substrate) {
        substrate.substrateType = VelodromeSubstrateType(uint256(bytes32Substrate) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate);
    }
}
