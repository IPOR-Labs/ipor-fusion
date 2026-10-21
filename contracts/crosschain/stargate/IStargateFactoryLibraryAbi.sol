// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IStargateFactoryLibraryAbi
/// @notice ABI declarations for errors raised by StargateFactoryLib that StargateCrosschainFactory does not declare itself.
/// @dev Declarations only. Linked libraries run under delegatecall, so their errors are raised from the host
///      address but only appear in the host ABI if declared here. Adds no runtime bytecode. Kept complete by
///      CrosschainLibraryAbiCompletenessTest.
/// @author IPOR Labs
interface IStargateFactoryLibraryAbi {
    error CreationCodeTooLarge();
    error NotAContract(address target);
    error StargatePoolAssetMismatch(address expectedAsset, address poolToken);
    error InvalidDecimals(uint8 localDecimals, uint8 sharedDecimals);
}
