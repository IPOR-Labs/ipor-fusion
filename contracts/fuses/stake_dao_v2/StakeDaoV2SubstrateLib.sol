// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

enum StakeDaoV2SubstrateType {
    UNDEFINED,
    RewardVault,
    ExtraRewardToken
}

struct StakeDaoV2Substrate {
    StakeDaoV2SubstrateType substrateType;
    address substrateAddress;
}

library StakeDaoV2SubstrateLib {
    function substrateToBytes32(StakeDaoV2Substrate memory substrate) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(substrate.substrateAddress)) | (uint256(substrate.substrateType) << 160));
    }

    function bytes32ToSubstrate(bytes32 bytes32Substrate) internal pure returns (StakeDaoV2Substrate memory substrate) {
        substrate.substrateType = StakeDaoV2SubstrateType(uint256(bytes32Substrate) >> 160);
        substrate.substrateAddress = PlasmaVaultConfigLib.bytes32ToAddress(bytes32Substrate);
    }
}
