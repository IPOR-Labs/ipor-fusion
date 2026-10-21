// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateLzSendAbi
/// @notice ABI declarations for errors raised by StargateLzSendLib.
/// @dev Declarations only. Linked libraries run under delegatecall, so their events/errors are
///      emitted/raised from the host address but only appear in the host ABI if declared here.
///      Adds no runtime bytecode. Kept complete by CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface IStargateLzSendAbi {
    error InsufficientNativeBudget(uint256 have, uint256 need);
    error NativeFeeTooHigh(uint256 fee, uint256 maxNativeFee);
    error PathConfigOptionsInvalid(uint256 chainId, uint16 msgType);
}
