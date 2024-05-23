// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.20;

enum TimeLockType {
    AtomistTransfer,
    AccessControl
}

interface IGuardElectron {
    /// @notice It retrieves the address of the current Atomist.
    /// @return The address of the current Atomist.
    /// @dev This function is used to get the address of the current Atomist in the contract.
    function getAtomist() external view returns (address);

    /// @notice It checks if the specified actor has access to a given function in a contract.
    /// @param contractAddress_ The address of the contract to check.
    /// @param functionSignature_ The signature of the function to check.
    /// @param actor_ The address of the actor to check for access.
    /// @return True if the actor has access to the specified function in the given contract, otherwise false.
    /// @dev This function verifies whether a particular actor has been granted access to a specific function in a contract.
    function hasAccess(
        address contractAddress_,
        bytes4 functionSignature_,
        address actor_
    ) external view returns (bool);

    /// @notice It sets a new time lock for a specified TimeLockType.
    /// @param timeLockType_ The type of time lock to set.
    /// @param newTimeLock_ The new duration for the time lock, in seconds.
    /// @dev This function allows setting a new time lock duration for a specific type of time lock.
    function setTimeLock(TimeLockType timeLockType_, uint32 newTimeLock_) external;

    /// @notice It appoints an actor to have access to a specific function in a contract.
    /// @param contractAddress_ The address of the contract to which access is being granted.
    /// @param functionName_ The signature of the function to which access is being granted.
    /// @param actor_ The address of the actor being granted access.
    /// @dev This function is used to appoint an actor with access rights to a specific function within a contract.
    function appointedToAccess(address contractAddress_, bytes4 functionName_, address actor_) external;

    /// @notice It grants access to a specific function in a contract to a specified actor.
    /// @param contractAddress_ The address of the contract to which access is being granted.
    /// @param functionName_ The signature of the function to which access is being granted.
    /// @param actor_ The address of the actor being granted access.
    /// @dev This function allows granting access to a specific function within a contract to a specified actor.
    function grantAccess(address contractAddress_, bytes4 functionName_, address actor_) external;

    /// @notice It revokes access to a specific function in a contract from a specified actor.
    /// @param contractAddress_ The address of the contract from which access is being revoked.
    /// @param functionName_ The signature of the function from which access is being revoked.
    /// @param actor_ The address of the actor whose access is being revoked.
    /// @dev This function allows revoking access to a specific function within a contract from a specified actor.
    function revokeAccess(address contractAddress_, bytes4 functionName_, address actor_) external;

    /// @notice It adds multiple addresses as pause guardians.
    /// @param guardians_ An array of addresses to be added as pause guardians.
    /// @dev This function allows adding multiple addresses to the list of pause guardians who can pause specific functions within the contract.
    function addPauseGuardians(address[] calldata guardians_) external;

    /// @notice It removes multiple addresses from the list of pause guardians.
    /// @param guardians_ An array of addresses to be removed from the list of pause guardians.
    /// @dev This function allows removing multiple addresses from the list of pause guardians who can pause specific functions within the contract.
    function removePauseGuardians(address[] calldata guardians_) external;

    /// @notice It pauses specific functions in multiple contracts.
    /// @param contractAddresses_ An array of contract addresses whose functions are to be paused.
    /// @param functionSignatures_ An array of function signatures to be paused in the corresponding contracts.
    /// @dev This function allows pausing specific functions in multiple contracts by specifying the contract addresses and function signatures.ł
    function pause(address[] calldata contractAddresses_, bytes4[] memory functionSignatures_) external;

    /// @notice It unpauses specific functions in multiple contracts.
    /// @param contractAddresses_ An array of contract addresses whose functions are to be unpaused.
    /// @param functionSignatures_ An array of function signatures to be unpaused in the corresponding contracts.
    /// @dev This function allows unpausing specific functions in multiple contracts by specifying the contract addresses and function signatures.
    function unpause(address[] calldata contractAddresses_, bytes4[] memory functionSignatures_) external;

    /// @notice It disables the whitelist for a specific function in a contract.
    /// @param contractAddress_ The address of the contract for which the whitelist is being disabled.
    /// @param functionSignature_ The signature of the function for which the whitelist is being disabled.
    /// @dev This function allows disabling the whitelist for a specific function within a contract.
    function disableWhiteList(address contractAddress_, bytes4 functionSignature_) external;

    /// @notice It enables the whitelist for a specific function in a contract.
    /// @param contractAddress_ The address of the contract for which the whitelist is being enabled.
    /// @param functionSignature_ The signature of the function for which the whitelist is being enabled.
    /// @dev This function allows enabling the whitelist for a specific function within a contract.
    function enableWhiteList(address contractAddress_, bytes4 functionSignature_) external;
}
