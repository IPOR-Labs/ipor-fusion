// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC5805} from "@openzeppelin/contracts/interfaces/IERC5805.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";

/**
 * @title IPlasmaVaultVotesExtension
 * @notice Interface for the optional PlasmaVault Votes Extension
 * @dev Extends IERC5805 (which combines IVotes and IERC6372) with additional methods
 *
 * This interface defines the contract that provides optional ERC20Votes functionality
 * for PlasmaVault. When enabled, it allows vault shares to be used for governance voting.
 *
 * Key Features:
 * - Vote delegation support
 * - Historical voting power tracking via checkpoints
 * - EIP-712 signature-based delegation (delegateBySig)
 * - Compound-compatible voting interface
 *
 * Integration:
 * - Called via delegatecall from PlasmaVault
 * - Uses same storage slots as OpenZeppelin VotesUpgradeable (ERC-7201)
 * - Shares nonces with ERC20Permit (same NoncesUpgradeable storage)
 *
 * Gas Optimization:
 * - Vaults without governance save ~2800-9800 gas per transfer
 * - Only vaults that enable this extension pay the voting overhead
 */
interface IPlasmaVaultVotesExtension is IERC5805 {
    /**
     * @notice Transfers voting units from one address to another
     * @dev Called by PlasmaVaultBase._update() during token transfers
     *
     * This function updates the voting checkpoints when tokens are transferred.
     * It should only be called via delegatecall from PlasmaVaultBase.
     *
     * @param from_ The address tokens are transferred from (address(0) for mints)
     * @param to_ The address tokens are transferred to (address(0) for burns)
     * @param amount_ The amount of tokens being transferred
     */
    function transferVotingUnits(address from_, address to_, uint256 amount_) external;

    /**
     * @notice Returns the number of checkpoints for an account
     * @param account_ The address to query checkpoints for
     * @return The number of checkpoints
     */
    function numCheckpoints(address account_) external view returns (uint32);

    /**
     * @notice Returns a specific checkpoint for an account
     * @param account_ The address to query
     * @param pos_ The checkpoint index (0-based)
     * @return The checkpoint at the given position
     */
    function checkpoints(address account_, uint32 pos_) external view returns (Checkpoints.Checkpoint208 memory);
}
