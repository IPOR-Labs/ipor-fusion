// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

enum VelodromeSuperchainSubstrateType {
    UNDEFINED,
    Gauge,
    Pool
}

struct VelodromeSuperchainSubstrate {
    VelodromeSuperchainSubstrateType substrateType;
    address substrateAddress;
}

library VelodromeSuperchainSubstrateLib {
    function substrateToBytes32(VelodromeSuperchainSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate_
    ) internal pure returns (VelodromeSuperchainSubstrate memory substrate) {
        substrate.substrateType = VelodromeSuperchainSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }
}
