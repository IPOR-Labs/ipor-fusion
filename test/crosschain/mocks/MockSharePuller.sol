// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Indirect rescue target that spends a pre-existing allowance over a share token (simulates a
///         leftover grant): the rescue targets THIS contract, not the vault, so only the post-call share
///         snapshot can see the drain (IL-8556).
/// @dev The entry point has the `transfer(address,uint256)` shape, one of the few a dispatcher rescue may carry
///      (IL-9654): it pulls `amount_` of `TOKEN` from the caller to `to_`. An amount of 0 is a harmless call.
contract MockSharePuller {
    IERC20 public immutable TOKEN;

    constructor(IERC20 token_) {
        TOKEN = token_;
    }

    function transfer(address to_, uint256 amount_) external returns (bool) {
        if (amount_ > 0) TOKEN.transferFrom(msg.sender, to_, amount_);
        return true;
    }
}
