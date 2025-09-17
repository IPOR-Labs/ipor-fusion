// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

enum EbisuZapperSubstrateType {
    UNDEFINED,
    Zapper,
    Registry
}

struct EbisuZapperSubstrate {
    EbisuZapperSubstrateType substrateType;
    address substrateAddress;
}

library EbisuZapperSubstrateLib {
    function substrateToBytes32(EbisuZapperSubstrate memory substrate_) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate_.substrateAddress)) | (uint256(substrate_.substrateType) << 160));
    }

    function bytes32ToSubstrate(
        bytes32 bytes32Substrate_
    ) internal pure returns (EbisuZapperSubstrate memory substrate) {
        substrate.substrateType = EbisuZapperSubstrateType(uint256(bytes32Substrate_) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate_);
    }
}
