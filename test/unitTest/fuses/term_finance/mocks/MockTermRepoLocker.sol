// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Minimal mock of `TermRepoLocker` used by the borrower-side collateral fuse tests.
/// @dev The fuse approves THIS contract (not the CollateralManager) for the collateral pull.
///      `TermRepoCollateralManager.externalLockCollateral` then calls
///      `transferTokenFromWallet(borrower, token, amount)` on the locker, which executes
///      `transferFrom(borrower, address(this), amount)`. The borrower's approval to the
///      locker is what authorises the pull — mirrors the live Term Finance impl.
contract MockTermRepoLocker {
    /// @notice Pull `amount` of `token` from `wallet` into this locker. Mirrors the live
    ///         `TermRepoLocker.transferTokenFromWallet` signature.
    function transferTokenFromWallet(address wallet_, address token_, uint256 amount_) external {
        IERC20(token_).transferFrom(wallet_, address(this), amount_);
    }

    /// @notice Reverse of `transferTokenFromWallet` — push `amount` of `token` from this
    ///         locker back to `wallet`. Used by `externalUnlockCollateral`.
    function transferTokenToWallet(address wallet_, address token_, uint256 amount_) external {
        IERC20(token_).transfer(wallet_, amount_);
    }
}
