// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Indirect rescue target that spends a pre-existing allowance over a share token (simulates a
///         leftover grant): the rescue targets THIS contract, not the vault, so only the post-call share
///         snapshot can see the drain (IL-8556).
contract MockSharePuller {
    function pull(IERC20 token_, address from_, address to_, uint256 amount_) external {
        token_.transferFrom(from_, to_, amount_);
    }

    function noop() external {}
}
