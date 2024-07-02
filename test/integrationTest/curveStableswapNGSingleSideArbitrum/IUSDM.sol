// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

/**
 * @dev USDM Interface.
 */
interface IUSDM {
    /**
     * @dev Checks if the specified address is blocked.
     */
    function isBlocked(address) external view returns (bool);

    /**
     * @dev Returns true if the contract is paused, and false otherwise.
     */
    function paused() external view returns (bool);

    /**
     * @notice Creates new tokens to the specified address.
     * @dev See {_mint}.
     * @param to The address to mint the tokens to.
     * @param amount The amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external;
}
