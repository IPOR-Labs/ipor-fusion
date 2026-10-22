// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {CREATE3} from "solady/utils/CREATE3.sol";

/// @notice Chain-agnostic deployment anchor for CCIP factories.
/// @dev Deploy this contract at the same address on every chain. CREATE3 then makes the
///      factory address independent of chain-specific constructor arguments such as Router.
contract CcipCreate3Deployer {
    error OnlyOwner();
    error EmptyCreationCode();
    error ZeroAddress();

    address public immutable OWNER;

    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroAddress();
        OWNER = owner_;
    }

    function deploy(bytes32 salt_, bytes calldata creationCode_) external returns (address deployed) {
        if (msg.sender != OWNER) revert OnlyOwner();
        if (creationCode_.length == 0) revert EmptyCreationCode();
        deployed = CREATE3.deploy(salt_, creationCode_, 0);
    }

    function getDeployed(bytes32 salt_) external view returns (address) {
        return CREATE3.getDeployed(salt_, address(this));
    }
}
