// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateOAppBase} from "../../../contracts/crosschain/stargate/base/StargateOAppBase.sol";
import {MsgType} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title StargateBaseHarness
/// @notice Tiny concrete `StargateOAppBase` that exposes the internal decimal conversions for direct unit
///         testing of `_toSD`/`_toLD` (round-trips, dust truncation, identity). Abstract inbound hooks are
///         stubbed (never exercised here).
contract StargateBaseHarness is StargateOAppBase {
    constructor(
        address endpoint_,
        address owner_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        address asset_,
        address stargatePool_
    ) StargateOAppBase(endpoint_, owner_, admin_, guardian_, rescueDelay_, asset_, stargatePool_) {}

    function toSD(uint256 localAmount_) external view returns (uint256) {
        return _toSD(localAmount_);
    }

    function toLD(uint256 sharedAmount_) external view returns (uint256) {
        return _toLD(sharedAmount_);
    }

    function _handleLzMessage(MsgType, uint256, Origin calldata, bytes memory) internal override {}

    function _handleCompose(uint256, bytes32, uint256, MsgType, bytes memory) internal override {}
}
