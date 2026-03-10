// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title ITokiPoolToken
 * @notice Interface for Napier v2 Toki pool tokens used by IPOR Fusion fuses.
 * @dev Exposes the minimal surface required for swap and accounting integrations.
 */
interface ITokiPoolToken is IERC20 {
    function i_poolKey() external view returns (PoolKey memory);

    function i_hook() external view returns (address);
}
