// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
    /// @dev This function extracts the 20-byte address, isCollateral (1 bit), canBorrow (1 bit), and subAccounts (1 byte) from the `bytes32` data
    function bytes32ToSubstrate(bytes32 data) internal view returns (EulerSubstrate memory substrate) {
        substrate.eulerVault = address(uint160(uint256(data) >> 96)); // Extract the 20-byte address by shifting right 96 bits
        substrate.isCollateral = (uint8(uint256(data) >> 88) & 0x01) == 1; // Extract isCollateral (1 bit) by shifting 88 bits and masking with 0x01
        substrate.canBorrow = (uint8(uint256(data) >> 80) & 0x01) == 1; // Extract canBorrow (1 bit) by shifting 80 bits and masking with 0x01
        substrate.subAccounts = bytes1(uint8(uint256(data) >> 72)); // Extract subAccounts (1 byte) by shifting 72 bits

        return substrate;
    }

    /// @notice Checks if the specified vault and sub-account can supply assets
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can supply assets in the market, false otherwise
    function canSupply(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);

        uint256 len = substrates.length;

        EulerSubstrate memory substrate;

        for (uint256 i = 0; i < len; i++) {
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if the specified vault and sub-account can be used as collateral
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can be used as collateral in the market, false otherwise
    function canCollateral(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        EulerSubstrate memory substrate;
        for (uint256 i = 0; i < len; i++) {
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount && substrate.isCollateral) {
                return true;
            }
        }
        return false;
    }

    /// @notice Checks if the specified vault and sub-account can borrow assets
    /// @param vault The address of the vault to check
    /// @param subAccount The sub-account identifier
    /// @param marketId The market identifier
    /// @return True if the vault and sub-account can borrow assets in the market, false otherwise
    function canBorrow(uint256 marketId, address vault, bytes1 subAccount) internal view returns (bool) {
        bytes32[] memory substrates = PlasmaVaultConfigLib.getMarketSubstrates(marketId);
        uint256 len = substrates.length;

        EulerSubstrate memory substrate;

        for (uint256 i = 0; i < len; i++) {
            substrate = bytes32ToSubstrate(substrates[i]);
            if (substrate.eulerVault == vault && substrate.subAccounts == subAccount && substrate.canBorrow) {
                return true;
            }
        }
        return false;
    }

    /// @notice Generates a sub-account address for a given plasma vault and sub-account identifier
    /// @param plasmaVault The address of the plasma vault
    /// @param subAccountId The sub-account identifier
    function generateSubAccountAddress(address plasmaVault, bytes1 subAccountId) internal pure returns (address) {
        return address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
    }
}
