// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title IWithdrawManagerReleaseFunds
/// @notice Release of funds with an expected current reserve (IL-9653)
interface IWithdrawManagerReleaseFunds {
    /// @notice releaseFunds: the current `sharesToRelease` differs from the value the caller expected (IL-9653)
    /// @param expected The reserve the caller expected
    /// @param actual The reserve currently recorded
    error WithdrawManagerSharesToReleaseChanged(uint256 expected, uint256 actual);

    /// @notice Releases funds like `releaseFunds(uint256,uint256)`, but only when the current `sharesToRelease` still
    /// equals `expectedSharesToRelease_`
    /// @dev A `redeemFromRequest` between the keeper's read and its transaction lowers the recorded reserve, so the
    /// call reverts instead of reserving those shares a second time. The two-argument overload stays for corrections:
    /// it overwrites the reserve unconditionally. The expected-value release can be front-run by a small
    /// `redeemFromRequest` (it reverts `WithdrawManagerSharesToReleaseChanged`): keepers re-read `sharesToRelease` and
    /// retry
    /// @param timestamp_ The release funds timestamp (in the past)
    /// @param sharesToRelease_ The new reserve
    /// @param expectedSharesToRelease_ The reserve the caller read before sending the transaction
    /// @custom:access ALPHA_ROLE
    function releaseFunds(uint256 timestamp_, uint256 sharesToRelease_, uint256 expectedSharesToRelease_) external;
}
