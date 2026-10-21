// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateAssetSendAbi
/// @notice ABI declarations for errors raised by StargateAssetSendLib (including the OpenZeppelin SafeERC20/Address errors it can bubble up).
/// @dev Declarations only. Linked libraries run under delegatecall, so their events/errors are
///      emitted/raised from the host address but only appear in the host ABI if declared here.
///      Adds no runtime bytecode. Kept complete by CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface IStargateAssetSendAbi {
    error AddressEmptyCode(address target);
    error AddressInsufficientBalance(address account);
    error FailedInnerCall();
    error SafeERC20FailedOperation(address token);
}
