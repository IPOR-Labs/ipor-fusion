// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title Interface for Syrup contract
interface ISyrup {
    /**
     * @dev Claims a token allocation.
     *      Can only claim a token allocation once.
     *      Can only be claimed before the deadline expires.
     *      Can only be claimed if the Merkle proof is valid.
     * @param id Unique identifier of the token allocation.
     * @param account Address of the token recipient.
     * @param claimAmount Amount of tokens to claim.
     * @param proof Proof that the recipient is part of the Merkle tree of token allocations.
     */
    function claim(uint256 id, address account, uint256 claimAmount, bytes32[] calldata proof) external;

    /**
     * @dev Returns the asset address in which rewards are transferred.
     * @return asset The address of the reward token.
     */
    function asset() external view returns (address asset);
}
