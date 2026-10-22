// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Minimal ERC20-shaped mock exposing only `decimals()`, used as a Balancer pool token in
///         BalancerBalanceFuse unit tests. BalancerBalanceFuse never calls `balanceOf`/`transfer` on
///         pool tokens directly (only on the pool/BPT itself and the gauge), so only `decimals()` is
///         needed to exercise `_convertToUsd`'s `IERC20Metadata(token_).decimals()` call.
contract MockERC20DecimalsForBalance {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
