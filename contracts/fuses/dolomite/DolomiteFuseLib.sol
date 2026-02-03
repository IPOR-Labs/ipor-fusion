// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/**
 * @title DolomiteSubstrate
 * @notice Data structure representing a substrate configuration for Dolomite protocol fuses
 *
 * @dev Dolomite Protocol Architecture Overview:
 *      =========================================
 *      Dolomite uses a unique "sub-account" system where a single address (owner) can have
 *      up to 256 isolated margin accounts (numbered 0-255). Each sub-account maintains
 *      independent positions, collateral, and risk parameters.
 *
 *      Key Concepts:
 *      - Sub-accounts: Numbered 0-255, allowing position isolation within a single address
 *      - Wei Balance: Dolomite uses signed integers where positive = supply, negative = debt
 *      - Markets: Each asset has a unique market ID within Dolomite Margin
 *
 *      The DolomiteSubstrate structure encodes:
 *      - Which asset can be used
 *      - Which sub-account the asset can be used in
 *      - Whether borrowing is permitted for this asset/sub-account combination
 *
 *      This allows Atomists (vault configurators) to precisely control:
 *      - Which assets Alphas (strategy operators) can interact with
 *      - Which sub-accounts are available for use
 *      - Whether leverage (borrowing) is allowed per asset
 */
struct DolomiteSubstrate {
    /// @notice The address of the underlying ERC20 asset (token)
    /// @dev Must be a valid token address supported by Dolomite Margin
    address asset;
    /// @notice Sub-account number for Dolomite operations
    /// @dev Range: 0-255. Each sub-account is an isolated margin account.
    ///      Sub-account 0 is typically the "main" account, while 1-255 can be used
    ///      for isolated strategies, borrow positions, or risk segregation.
    uint8 subAccountId;
    /// @notice Boolean flag indicating if borrowing is allowed for this asset/sub-account
    /// @dev When true: Asset can be supplied AND borrowed (creates negative Wei balance)
    ///      When false: Asset can only be supplied (supply-only, no leverage)
    ///      This flag controls:
    ///      - Whether DolomiteBorrowFuse can create debt with this asset
    ///      - How DolomiteBalanceFuse accounts for negative balances
    ///      - Whether instant withdrawals are possible (no borrow = instant OK)
    bool canBorrow;
}

/**
 * @title DolomiteFuseLib
 * @author IPOR Labs
 * @notice Library for handling operations related to Dolomite protocol fuses
 *
 * @dev This library provides core utilities for the Dolomite fuse system:
 *
 *      1. SUBSTRATE ENCODING/DECODING:
 *         The DolomiteSubstrate struct is encoded into bytes32 for efficient storage
 *         in PlasmaVaultConfigLib. The encoding layout is:
 *
 *         bytes32 layout (256 bits total):
 *         ┌─────────────────────────────────────────────────────────────────┐
 *         │ bits 96-255 (160 bits) │ bits 88-95 (8 bits) │ bits 80-87 (8 bits) │
 *         │ asset address          │ subAccountId        │ canBorrow flag      │
 *         └─────────────────────────────────────────────────────────────────┘
 *
 *         Note: Bits 0-79 are unused/zero-padded for future extensibility.
 *
 *      2. PERMISSION CHECKS:
 *         - canSupply(): Checks if an asset/sub-account can be used for deposits
 *         - canBorrow(): Checks if an asset/sub-account allows debt creation
 *         - canInstantWithdraw(): Checks if position allows immediate withdrawal
 *
 *      3. SUB-ACCOUNT ENUMERATION:
 *         - getSubAccountIds(): Returns all sub-account IDs configured for a market
 *
 *      Integration with PlasmaVault:
 *      - Substrates are stored via PlasmaVaultConfigLib.grantMarketSubstrates()
 *      - Retrieved via PlasmaVaultConfigLib.getMarketSubstrates()
 *      - Each substrate represents one allowed asset/sub-account/permission combination
 */
library DolomiteFuseLib {
    /**
     * @notice Converts a DolomiteSubstrate struct to a bytes32 representation
     * @param substrate The DolomiteSubstrate struct to convert
     * @return The packed bytes32 representation of the substrate
     *
     * @dev Bit-packing layout for efficient storage:
     *
     *      Example: asset=0xABCD...1234, subAccountId=5, canBorrow=true
     *
     *      Step 1: Shift asset address left by 96 bits
     *              (fills bits 96-255 with the 160-bit address)
     *
     *      Step 2: Shift subAccountId left by 88 bits
     *              (fills bits 88-95 with the 8-bit sub-account ID)
     *
     *      Step 3: Shift canBorrow (0 or 1) left by 80 bits
     *              (fills bit 80 with the boolean flag)
     *
     *      Step 4: OR all values together into single bytes32
     *
     *      This encoding is gas-efficient as it stores 3 values in one storage slot
     *      and can be decoded with simple bit operations.
     */
    function substrateToBytes32(DolomiteSubstrate memory substrate) internal pure returns (bytes32) {
        return
            bytes32(
                // Pack asset address into bits 96-255 (leftmost 160 bits)
                (uint256(uint160(substrate.asset)) << 96) |
                    // Pack subAccountId into bits 88-95 (8 bits after address)
                    (uint256(substrate.subAccountId) << 88) |
                    // Pack canBorrow flag into bits 80-87 (1 bit used, 7 zero-padded)
                    (uint256(substrate.canBorrow ? 1 : 0) << 80)
            );
    }

    /**
     * @notice Converts a bytes32 representation to a DolomiteSubstrate struct
     * @param data The packed bytes32 data to convert
     * @return substrate The decoded DolomiteSubstrate struct
     *
     * @dev Unpacking process (reverse of substrateToBytes32):
     *
     *      Step 1: Right-shift by 96 bits to extract asset address
     *              This moves bits 96-255 to bits 0-159, then truncate to address
     *
     *      Step 2: Right-shift by 88 bits, cast to uint8 to extract subAccountId
     *              This isolates bits 88-95 and takes the lowest 8 bits
     *
     *      Step 3: Right-shift by 80 bits, mask with 0x01 to extract canBorrow
     *              This isolates bit 80 and checks if it's 1 (true) or 0 (false)
     */
    function bytes32ToSubstrate(bytes32 data) internal pure returns (DolomiteSubstrate memory substrate) {
        // Extract asset address from bits 96-255
        substrate.asset = address(uint160(uint256(data) >> 96));

        // Extract subAccountId from bits 88-95
        substrate.subAccountId = uint8(uint256(data) >> 88);

        // Extract canBorrow flag from bit 80 (mask with 0x01 to get boolean)
        substrate.canBorrow = (uint8(uint256(data) >> 80) & 0x01) == 1;

        return substrate;
    }

    /// @notice Checks if the specified asset and sub-account can supply to Dolomite
    function canSupply(uint256 marketId, address asset, uint8 subAccountId) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        bytes32 patternWithBorrow = substrateToBytes32(DolomiteSubstrate(asset, subAccountId, true));
        bytes32 patternWithoutBorrow = substrateToBytes32(DolomiteSubstrate(asset, subAccountId, false));

        for (uint256 i; i < len; ++i) {
            if (substrates[i] == patternWithBorrow || substrates[i] == patternWithoutBorrow) {
                return true;
            }
        }

        return false;
    }

    /// @notice Checks if the specified asset and sub-account can borrow from Dolomite
    function canBorrow(uint256 marketId, address asset, uint8 subAccountId) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        bytes32 pattern = substrateToBytes32(DolomiteSubstrate(asset, subAccountId, true));

        for (uint256 i; i < len; ++i) {
            if (substrates[i] == pattern) {
                return true;
            }
        }

        return false;
    }

    /// @notice Checks if instant withdrawal is allowed for an asset/sub-account
    function canInstantWithdraw(uint256 marketId, address asset, uint8 subAccountId) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        bytes32 pattern = substrateToBytes32(DolomiteSubstrate(asset, subAccountId, false));

        for (uint256 i; i < len; ++i) {
            if (substrates[i] == pattern) {
                return true;
            }
        }

        return false;
    }

    /**
     * @notice Gets all sub-account IDs from configured substrates
     * @param marketId The Fusion market identifier
     * @return subAccountIds Array of sub-account IDs (may contain duplicates)
     *
     * @dev This function extracts all sub-account IDs from the market's substrates.
     *
     *      IMPORTANT: The returned array may contain duplicate sub-account IDs
     *      if multiple assets are configured for the same sub-account.
     *      Callers should deduplicate if needed.
     *
     *      Example scenario:
     *      - Substrate 1: USDC, subAccountId=0, canBorrow=false
     *      - Substrate 2: WETH, subAccountId=0, canBorrow=true
     *      - Substrate 3: USDC, subAccountId=1, canBorrow=true
     *
     *      This would return: [0, 0, 1] (with duplicates)
     *
     *      Used by: DolomiteBalanceFuse to enumerate all sub-accounts that need
     *      balance calculation for the vault's total assets.
     */
    function getSubAccountIds(uint256 marketId) internal view returns (uint8[] memory) {
        // Retrieve all substrates configured for this Fusion market
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        // Allocate array to hold all sub-account IDs (including potential duplicates)
        uint8[] memory subAccountIds = new uint8[](len);

        // Extract sub-account ID from each substrate
        for (uint256 i; i < len; ++i) {
            subAccountIds[i] = bytes32ToSubstrate(substrates[i]).subAccountId;
        }

        return subAccountIds;
    }
}
