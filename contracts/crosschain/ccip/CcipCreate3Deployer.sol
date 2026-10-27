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

    /// @notice Deploy `creationCode_` through CREATE3.
    /// @dev Owner-only (`OnlyOwner`); empty code reverts `EmptyCreationCode`. The address depends only on `salt_`
    ///      and this deployer's address, not on `creationCode_`, and no value is forwarded (CREATE3 with value 0).
    /// @return deployed Address of the new contract.
    function deploy(bytes32 salt_, bytes calldata creationCode_) external returns (address deployed) {
        if (msg.sender != OWNER) revert OnlyOwner();
        if (creationCode_.length == 0) revert EmptyCreationCode();
        deployed = CREATE3.deploy(salt_, creationCode_, 0);
    }

    /// @notice Address `deploy` yields for `salt_`, computed without deploying.
    function getDeployed(bytes32 salt_) external view returns (address) {
        return CREATE3.getDeployed(salt_, address(this));
    }
}
