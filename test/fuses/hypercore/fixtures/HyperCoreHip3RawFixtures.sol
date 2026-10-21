// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/// @notice Read-only mainnet HyperEVM precompile responses for HIP-3 (builder-deployed) perp dexes,
///         captured 2026-09-28.
/// @dev These are eth_call return bytes for `perpAssetInfo` (0x80A) at HIP-3 read indices and for
///      `accountMarginSummary` (0x80F) on a HIP-3 dex, not outputs synthesized with abi.encode.
library HyperCoreHip3RawFixtures {
    /// @notice `perpAssetInfo(10002)` — market `xyz:NVDA` (dex 1, index 2), decodes to
    /// `("xyz:NVDA", marginTableId 20, szDecimals 3, maxLeverage 20, onlyIsolated false)`.
    function perpAssetInfoXyzNvda() internal pure returns (bytes memory) {
        return hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"00000000000000000000000000000000000000000000000000000000000000a0"
            hex"0000000000000000000000000000000000000000000000000000000000000014"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"0000000000000000000000000000000000000000000000000000000000000014"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"0000000000000000000000000000000000000000000000000000000000000008"
            hex"78797a3a4e564441000000000000000000000000000000000000000000000000";
    }

    /// @notice `perpAssetInfo(10107)` — market `xyz:SOXL`, decodes to
    /// `("xyz:SOXL", marginTableId 10, szDecimals 2, maxLeverage 10, onlyIsolated true)`.
    function perpAssetInfoXyzSoxl() internal pure returns (bytes memory) {
        return hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"00000000000000000000000000000000000000000000000000000000000000a0"
            hex"000000000000000000000000000000000000000000000000000000000000000a"
            hex"0000000000000000000000000000000000000000000000000000000000000002"
            hex"000000000000000000000000000000000000000000000000000000000000000a"
            hex"0000000000000000000000000000000000000000000000000000000000000001"
            hex"0000000000000000000000000000000000000000000000000000000000000008"
            hex"78797a3a534f584c000000000000000000000000000000000000000000000000";
    }

    /// @notice `perpAssetInfo(80000)` — market `para:TOTAL2`, decodes to
    /// `("para:TOTAL2", marginTableId 20, szDecimals 3, maxLeverage 20, onlyIsolated false)`.
    function perpAssetInfoParaTotal2() internal pure returns (bytes memory) {
        return hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"00000000000000000000000000000000000000000000000000000000000000a0"
            hex"0000000000000000000000000000000000000000000000000000000000000014"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"0000000000000000000000000000000000000000000000000000000000000014"
            hex"0000000000000000000000000000000000000000000000000000000000000000"
            hex"000000000000000000000000000000000000000000000000000000000000000b"
            hex"706172613a544f54414c32000000000000000000000000000000000000000000";
    }

    /// @notice `perpAssetInfo(100001)` — market `io:ANTH`, decodes to
    /// `("io:ANTH", marginTableId 6, szDecimals 3, maxLeverage 6, onlyIsolated true)`.
    function perpAssetInfoIoAnth() internal pure returns (bytes memory) {
        return hex"0000000000000000000000000000000000000000000000000000000000000020"
            hex"00000000000000000000000000000000000000000000000000000000000000a0"
            hex"0000000000000000000000000000000000000000000000000000000000000006"
            hex"0000000000000000000000000000000000000000000000000000000000000003"
            hex"0000000000000000000000000000000000000000000000000000000000000006"
            hex"0000000000000000000000000000000000000000000000000000000000000001"
            hex"0000000000000000000000000000000000000000000000000000000000000007"
            hex"696f3a414e544800000000000000000000000000000000000000000000000000";
    }

    /// @notice `accountMarginSummary(1, xyzHolder)` — one atomic snapshot at EVM block 47081710,
    /// decodes to `(accountValue 9386090926, marginUsed 8592359262, ntlPos 159999504640,
    /// rawUsd -150613413714)`.
    function accountMarginSummaryXyzHolder() internal pure returns (bytes memory) {
        return hex"000000000000000000000000000000000000000000000000000000022f7461ae"
            hex"000000000000000000000000000000000000000000000000000000020024ff5e"
            hex"0000000000000000000000000000000000000000000000000000002540b6b100"
            hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffdceebdb0ae";
    }

    // -------------------------------------------------------------------
    // Typed constants decoded from the same atomic snapshot (not raw bytes).
    // -------------------------------------------------------------------

    /// @notice NVDA position (read index 10002) from the same snapshot as
    /// `accountMarginSummaryXyzHolder`.
    function nvdaPositionSzi() internal pure returns (int64) {
        return 586112;
    }

    function nvdaPositionEntryNtl() internal pure returns (uint64) {
        return 131686580850;
    }

    function nvdaPositionIsolatedRawUsd() internal pure returns (int64) {
        return 0;
    }

    function nvdaPositionLeverage() internal pure returns (uint32) {
        return 20;
    }

    function nvdaPositionIsIsolated() internal pure returns (bool) {
        return false;
    }

    function nvdaMarkPx() internal pure returns (uint64) {
        return 223970;
    }

    function nvdaOraclePx() internal pure returns (uint64) {
        return 223930;
    }

    /// @notice SOXL position (read index 10107) from the same snapshot as
    /// `accountMarginSummaryXyzHolder`.
    function soxlPositionSzi() internal pure returns (int64) {
        return 20000;
    }

    function soxlPositionEntryNtl() internal pure returns (uint64) {
        return 29673294500;
    }

    function soxlPositionIsolatedRawUsd() internal pure returns (int64) {
        return -26699215970;
    }

    function soxlPositionLeverage() internal pure returns (uint32) {
        return 10;
    }

    function soxlPositionIsIsolated() internal pure returns (bool) {
        return true;
    }

    function soxlMarkPx() internal pure returns (uint64) {
        return 1436400;
    }

    function soxlOraclePx() internal pure returns (uint64) {
        return 1435300;
    }
}
