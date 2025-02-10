// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

/**
 * @title IFluidMerkleDistributor
 * @notice Interface for interacting with FluidMerkleDistributor contract
 */
interface IFluidMerkleDistributor {
    /**
     * @notice Claims rewards for a given position
     * @param recipient_ The address that will receive the rewards
     * @param cumulativeAmount_ The total amount of rewards claimable
     * @param positionType_ The type of position for which rewards are being claimed
     * @param positionId_ The unique identifier of the position
     * @param cycle_ The cycle number for which rewards are being claimed
     * @param merkleProof_ The merkle proof that validates this claim
     * @param metadata_ Additional metadata required for the claim
     */
    function claim(
        address recipient_,
        uint256 cumulativeAmount_,
        uint8 positionType_,
        bytes32 positionId_,
        uint256 cycle_,
        bytes32[] calldata merkleProof_,
        bytes memory metadata_
    ) external;

    /* solhint-enable func-name-mixedcase */
    function TOKEN() external view returns (address);
}
