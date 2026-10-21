// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {BusinessAction} from "../../lib/CrosschainConstants.sol";

/// @title CcipDecimalsLib
/// @notice Local <-> shared decimal conversion for the CCIP transport.
/// @dev Three conversions with DIFFERENT contracts, deliberately kept apart (audit C-2/H-2/M-3):
///      - `toSDExact` — only for amounts the protocol itself constructs and must round-trip byte-exactly
///        (manager-supplied send/recall amounts, normalized action data). Reverting is the point: it tells
///        the caller the amount carries dust that would be silently dropped.
///      - `toSDFloor` — for every MEASURED or EXTERNAL value (`convertToAssets`, realized ERC-4626 deltas,
///        inbound `destTokenAmounts`, off-chain balance observations). These are arbitrary integers; a
///        revert here would brick the message handler that reads them.
///      - `toSDCeil` — for DEBITS against a tracked ledger, so truncation can never leave the ledger
///        claiming value that is no longer held.
library CcipDecimalsLib {
    error AmountHasDust(uint256 amount);

    function toSDExact(uint256 amountLD_, uint256 rate_) public pure returns (uint256 amountSD) {
        if (amountLD_ % rate_ != 0) revert AmountHasDust(amountLD_);
        return amountLD_ / rate_;
    }

    /// @notice Truncating conversion — NEVER reverts. Use for measured/external values.
    function toSDFloor(uint256 amountLD_, uint256 rate_) public pure returns (uint256 amountSD) {
        return amountLD_ / rate_;
    }

    /// @notice Rounding-up conversion — NEVER reverts. Use when debiting a tracked ledger.
    /// @dev Overflow-free form: `(amountLD_ + rate_ - 1) / rate_` can wrap for amounts near 2^256 even though
    ///      the quotient is representable (IL-8592).
    ///      Internal on purpose: the dispatcher inlines it and is not linked against this library (the completeness
    ///      test pins the dispatcher's library list).
    function toSDCeil(uint256 amountLD_, uint256 rate_) internal pure returns (uint256 amountSD) {
        return amountLD_ / rate_ + (amountLD_ % rate_ == 0 ? 0 : 1);
    }

    function toLD(uint256 amountSD_, uint256 rate_) public pure returns (uint256) {
        return amountSD_ * rate_;
    }

    function normalizeActionData(uint8 action_, bytes calldata data_, uint256 rate_)
        public
        pure
        returns (bytes memory)
    {
        if (action_ == uint8(BusinessAction.DEPOSIT)) {
            (address vault, uint256 amount, uint256 minShares) = abi.decode(data_, (address, uint256, uint256));
            return abi.encode(vault, toSDExact(amount, rate_), minShares);
        }
        if (action_ == uint8(BusinessAction.REDEEM)) {
            (address vault, uint256 shares, uint256 minAssets) = abi.decode(data_, (address, uint256, uint256));
            return abi.encode(vault, shares, toSDExact(minAssets, rate_));
        }
        if (action_ == uint8(BusinessAction.REDEEM_FROM_REQUEST)) {
            (address manager, address vault, uint256 shares, uint256 minAssets, address receiver) =
                abi.decode(data_, (address, address, uint256, uint256, address));
            return abi.encode(manager, vault, shares, toSDExact(minAssets, rate_), receiver);
        }
        return data_;
    }
}
