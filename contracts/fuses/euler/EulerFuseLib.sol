// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @dev Struct representing a substrate in the Euler protocol fuses
/// @param eulerVault The address of the Euler vault
/// @param isCollateral Boolean indicating if the euler vault can be used as collateral
/// @param canBorrow Boolean indicating if one can borrowed against
/// @param subAccounts A byte representing sub-accounts
struct EulerSubstrate {
    address eulerVault;
    bool isCollateral;
    bool canBorrow;
    bytes1 subAccounts;
}

/// @title EulerFuseLib
/// @dev Library for handling operations related to Euler protocol fuses, including conversion between EulerSubstrate
///      structs and bytes32, and checking supply, collateral, and borrow capabilities.
library EulerFuseLib {
    /// @notice Converts an `EulerSubstrate` struct to a `bytes32` representation
    /// @param substrate The `EulerSubstrate` struct to convert
    /// @return The `bytes32` representation of the `EulerSubstrate` struct
    function substrateToBytes32(EulerSubstrate memory substrate) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint160(substrate.eulerVault)) << 96) | // Shift address by 96 bits to leave room for the rest
                    (uint256(uint8(substrate.isCollateral ? 1 : 0)) << 88) | // Shift isCollateral by 88 bits
                    (uint256(uint8(substrate.canBorrow ? 1 : 0)) << 80) | // Shift canBorrow by 80 bits
                    (uint256(uint8(substrate.subAccounts)) << 72) // Shift subAccounts by 72 bits
            );
    }

    /// @notice Converts a `bytes32` representation to an `EulerSubstrate` struct
    /// @param data The `bytes32` data to convert
    /// @return substrate The `EulerSubstrate` struct representation of the `bytes32` data
    /// @dev This function extracts the 20-byte address, isCollateral (1 byte, using 1 bit), canBorrow (1 byte, using 1 bit), and subAccounts (1 byte) from the `bytes32` data
    function bytes32ToSubstrate(bytes32 data) internal pure returns (EulerSubstrate memory substrate) {
        substrate.eulerVault = address(uint160(uint256(data) >> 96)); // Extract the 20-byte address by shifting right 96 bits
        substrate.isCollateral = (uint8(uint256(data) >> 88) & 0x01) == 1; // Extract isCollateral (1 bit) by shifting 88 bits and masking with 0x01
        substrate.canBorrow = (uint8(uint256(data) >> 80) & 0x01) == 1; // Extract canBorrow (1 bit) by shifting 80 bits and masking with 0x01
        substrate.subAccounts = bytes1(uint8(uint256(data) >> 72)); // Extract subAccounts (1 byte) by shifting 72 bits

        return substrate;
    }

    /// @notice Encodes an EulerSwap pool entry of a market substrate list
    /// @dev Layout: `[160-bit pool address][isCollateral byte = 0][canBorrow byte = 0][sub-account byte][kind byte = 0x01][64 bits of padding]`.
    ///      The kind byte sits right after the sub-account byte (bits 64-71), bit 64 marks a pool entry. The flag bytes are
    ///      always zero in an encoded pool entry. Entries written by `substrateToBytes32` keep bits 0-71 at zero, so no
    ///      existing eVault entry is read as a pool entry.
    /// @param pool The address of the EulerSwap pool
    /// @param subAccount The sub-account identifier the pool is installed for
    /// @return The `bytes32` representation of the pool entry
    function swapPoolSubstrateToBytes32(address pool, bytes1 subAccount) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint160(pool)) << 96) | // Shift address by 96 bits
                    (uint256(uint8(subAccount)) << 72) | // Sub-account byte at bits 72-79
                    (uint256(1) << 64) // Kind byte (bits 64-71) = 0x01, a pool entry
            );
    }

    /// @notice Checks whether a substrate entry is an EulerSwap pool entry
    /// @dev Predicate: `(uint8(uint256(data) >> 64) & 0x01) == 1`, i.e. bit 64 of the entry is set. The flag bytes
    ///      (bits 80-95) are not inspected: an entry with flag bytes set is still a pool entry and those flags are ignored.
    /// @param data The substrate entry
    /// @return True if the entry is a pool entry, false if it is an ordinary eVault entry
    function isSwapPoolSubstrate(bytes32 data) internal pure returns (bool) {
        return (uint8(uint256(data) >> 64) & 0x01) == 1;
    }

    /// @notice Decodes the pool address and the sub-account byte of an entry
    /// @dev Does not check the kind byte: call `isSwapPoolSubstrate` first when the entry origin is unknown
    /// @param data The substrate entry
    /// @return pool The pool address
    /// @return subAccount The sub-account byte
    function bytes32ToSwapPoolSubstrate(bytes32 data) internal pure returns (address pool, bytes1 subAccount) {
        pool = address(uint160(uint256(data) >> 96));
        subAccount = bytes1(uint8(uint256(data) >> 72));
    }

    /// @notice Checks whether the market has a pool entry for exactly this pool and sub-account
    /// @dev Only pool entries count; an ordinary eVault entry with the same address and sub-account does not
    /// @param marketId The market identifier
    /// @param pool The pool address
    /// @param subAccount The sub-account identifier
    /// @return True if a pool entry with this exact pair is listed, false otherwise
    function isSwapPoolGranted(uint256 marketId, address pool, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        for (uint256 i; i < len; ++i) {
            if (isSwapPoolSubstrate(substrates[i])) {
                (address entryPool, bytes1 entrySubAccount) = bytes32ToSwapPoolSubstrate(substrates[i]);
                if (entryPool == pool && entrySubAccount == subAccount) {
                    return true;
                }
            }
        }
        return false;
    }

    /// @notice Checks if the specified vault and sub-account can supply assets
    /// @dev EulerSwap pool entries are skipped
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can supply assets in the market, false otherwise
    function canSupply(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);

        uint256 len = substrates.length;

        EulerSubstrate memory substrate;

        for (uint256 i = 0; i < len; i++) {
            if (isSwapPoolSubstrate(substrates[i])) {
                continue;
            }
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if the specified vault and sub-account can be used as collateral
    /// @dev EulerSwap pool entries are skipped
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can be used as collateral in the market, false otherwise
    function canCollateral(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        EulerSubstrate memory substrate;
        for (uint256 i = 0; i < len; i++) {
            if (isSwapPoolSubstrate(substrates[i])) {
                continue;
            }
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount && substrate.isCollateral) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if the specified vault and sub-account can borrow assets
    /// @dev EulerSwap pool entries are skipped
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can borrow assets in the market, false otherwise
    function canBorrow(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        EulerSubstrate memory substrate;

        for (uint256 i = 0; i < len; i++) {
            if (isSwapPoolSubstrate(substrates[i])) {
                continue;
            }
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount && substrate.canBorrow) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if the specified Euler vault is granted in any substrate of the market
    /// @dev The flags and the sub-account of the substrate are not checked: any eVault entry with this Euler vault counts.
    ///      EulerSwap pool entries are skipped.
    /// @param marketId The market identifier
    /// @param vault The address of the Euler vault to check
    /// @return True if at least one substrate of the market has this Euler vault, false otherwise
    function isEulerVaultGranted(uint256 marketId, address vault) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        for (uint256 i; i < len; ++i) {
            if (!isSwapPoolSubstrate(substrates[i]) && bytes32ToSubstrate(substrates[i]).eulerVault == vault) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if instant withdraw is allowed for given substrate configuration
    /// @dev Every substrate entry matching the Euler vault and the sub-account is inspected, not only the first one:
    ///      the answer is true only when at least one entry matches and none of the matching entries carries
    ///      `isCollateral` or `canBorrow`. A later re-grant of the same pair with a blocking flag therefore disables
    ///      the instant withdraw even when an unflagged entry of the pair is listed first.
    /// @param marketId The market identifier
    /// @param vault The address of the Euler vault
    /// @param subAccount The sub-account identifier
    /// @return True if at least one entry matches and all matching entries have isCollateral == false AND canBorrow == false
    function canInstantWithdraw(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        EulerSubstrate memory substrate;
        bool found;

        for (uint256 i; i < len; ++i) {
            if (isSwapPoolSubstrate(substrates[i])) {
                continue;
            }
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount) {
                if (substrate.isCollateral || substrate.canBorrow) {
                    return false;
                }
                found = true;
            }
        }
        return found;
    }

    /// @notice Generates a sub-account address for a given plasma vault and sub-account identifier
    /// @param plasmaVault The address of the plasma vault
    /// @param subAccountId The sub-account identifier
    function generateSubAccountAddress(address plasmaVault, bytes1 subAccountId) internal pure returns (address) {
        return address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
    }
}
