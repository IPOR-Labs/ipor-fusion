// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../../libraries/PlasmaVaultConfigLib.sol";

/// @notice we need both the zapper address for operations, and registry address to validate the call
/// this substrate type allows us to discriminate between the two, since the balance Fuse must only iterate across the ZAPPER type substrates
enum EbisuZapperSubstrateType {
    UNDEFINED,
    ZAPPER,
    REGISTRY
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
