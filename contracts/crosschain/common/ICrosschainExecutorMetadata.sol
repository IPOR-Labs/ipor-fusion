// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CrosschainTransportKind} from "./CrosschainTransportTypes.sol";

/// @dev Implemented by CcipCrosschainExecutor only. StargateCrosschainExecutor does not implement this
///      interface: it declares neither transportKind() nor executorInterfaceVersion(), so casting a
///      Stargate executor to this interface and calling either member reverts.
interface ICrosschainExecutorMetadata {
    function transportKind() external pure returns (CrosschainTransportKind);
    function executorInterfaceVersion() external pure returns (uint32);
    function FACTORY() external view returns (address);
}
