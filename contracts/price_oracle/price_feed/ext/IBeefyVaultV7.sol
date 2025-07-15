// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.26;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";

interface IBeefyVaultV7 {
    /// @dev The token that the vault is depositing
    function want() external view returns (ERC20Upgradeable);

    /**
     * @dev Function for various UIs to dis play the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() external view returns (uint256);
}
