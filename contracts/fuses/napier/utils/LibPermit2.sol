// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPermit2} from "../../balancer/ext/IPermit2.sol";

library LibPermit2 {
    using SafeERC20 for ERC20;

    /// @notice Canonical Permit2 address
    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Sets up Permit2 approval for the router to pull tokens
    /// @param token The token to approve
    function setupPermit2Approval(address token, address spender) internal {
        // Some tokens built with Solady requires an infinite amount to Permit2 approval
        // We always approve an infinite amount to Permit2 to avoid the Permit2AllowanceIsFixedAtInfinity() error
        ERC20(token).forceApprove(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(token, spender, type(uint160).max, uint48(block.timestamp));
    }

    /// @notice Resets Permit2 approval after execution
    /// @param token The token to reset approval for
    function resetPermit2Approval(address token, address spender) internal {
        // Solady requires an infinite amount to Permi2 approval
        IPermit2(PERMIT2).approve(token, spender, 0, uint48(block.timestamp));
    }
}
