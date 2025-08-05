// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

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
    function substrateToBytes32(AerodromeSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate_
    ) internal pure returns (AerodromeSubstrate memory substrate_) {
        substrate_.substrateType = AerodromeSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate_.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }
}
