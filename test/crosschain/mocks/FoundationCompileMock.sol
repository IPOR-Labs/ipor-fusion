// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {StargateOAppBase} from "../../../contracts/crosschain/stargate/base/StargateOAppBase.sol";
import {MsgType} from "../../../contracts/crosschain/lib/CrosschainConstants.sol";
import {Origin} from "@layerzerolabs/lz-evm-protocol-v2/contracts/interfaces/ILayerZeroEndpointV2.sol";

/// @title FoundationCompileMock
/// @notice Minimal concrete `StargateOAppBase` used only to force the compiler to verify the full
///         foundation constructor chain (OZ5 `Ownable`, `OAppCore`, `RescueModule`, Stargate wiring)
///         and abstract-method coverage (`_handleLzMessage`, `_handleCompose`). Not for deployment.
/// @dev Kept in the test tree as a seed for later transport tests.
contract FoundationCompileMock is StargateOAppBase {
    constructor(
        address endpoint_,
        address owner_,
        address admin_,
        address guardian_,
        uint256 rescueDelay_,
        address asset_,
        address stargatePool_
    ) StargateOAppBase(endpoint_, owner_, admin_, guardian_, rescueDelay_, asset_, stargatePool_) {}

    function _handleLzMessage(MsgType, uint256, Origin calldata, bytes memory) internal override {}

    function _handleCompose(uint256, bytes32, uint256, MsgType, bytes memory) internal override {}
}
