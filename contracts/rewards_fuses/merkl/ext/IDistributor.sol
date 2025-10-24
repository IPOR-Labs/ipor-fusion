// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/// @title Interface for Merkl Distributor
interface IDistributor {
    /// @notice Claims rewards for multiple users and tokens with custom recipients
    /// @param users Array of user addresses to claim rewards for
    /// @param tokens Array of reward token addresses
    /// @param amounts Array of claimable amounts for each token
    /// @param proofs Array of merkle proofs for each token
    /// @param recipients Array of recipient addresses for each token
    /// @param datas Array of arbitrary data to pass to recipients
    function claimWithRecipient(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs,
        address[] calldata recipients,
        bytes[] memory datas
    ) external;

    /// @notice Claims rewards for a given set of users
    /// @dev Unless another address has been approved for claiming, only an address can claim for itself
    /// @param users Addresses for which claiming is taking place
    /// @param tokens ERC20 token claimed
    /// @param amounts Amount of tokens that will be sent to the corresponding users
    /// @param proofs Array of hashes bridging from a leaf `(hash of user | token | amount)` to the Merkle root
    function claim(
        address[] calldata users,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes32[][] calldata proofs
    ) external;
}
