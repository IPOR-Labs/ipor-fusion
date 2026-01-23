// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IPreHook} from "../IPreHook.sol";
import {PreHooksLib} from "../PreHooksLib.sol";

/// @title EIP7702DelegateValidationPreHook
/// @author IPOR Labs
/// @notice Pre-execution hook for validating EIP-7702 delegate targets against a governance-managed whitelist
/// @dev This contract implements the IPreHook interface to validate that EOA accounts using EIP-7702 delegation
///      have their delegate targets whitelisted. The whitelist is managed through substrates by governance (ATOMIST).
///
/// EIP-7702 Delegation Designator:
/// - EOA with delegation has code: 0xef0100 || address (23 bytes total)
/// - Prefix: 0xef0100 (3 bytes)
/// - Delegate target: implementation address (20 bytes)
///
/// Validation Flow:
/// 1. Check if tx.origin has code size of exactly 23 bytes
/// 2. If yes, read the code and verify the 0xef0100 prefix
/// 3. Extract the delegate target (last 20 bytes)
/// 4. Check if delegate target is in the whitelist (substrates)
/// 5. If not whitelisted, revert with InvalidDelegateTarget
///
/// Key features:
/// - Validates EIP-7702 delegate targets for tx.origin
/// - Whitelist managed through substrates by governance
/// - Allows regular EOA without delegation to pass
/// - Allows contracts with different code sizes to pass
/// - Gas efficient implementation using assembly
///
/// Security considerations:
/// - Protected by PlasmaVault's access control for hook registration
/// - Whitelist can only be modified by governance through substrates
/// - Uses tx.origin to check the original transaction sender
contract EIP7702DelegateValidationPreHook is IPreHook {
    /// @notice EIP-7702 delegation designator prefix
    bytes3 private constant EIP7702_PREFIX = 0xef0100;

    /// @notice Expected code size for EIP-7702 delegated accounts (3 bytes prefix + 20 bytes address)
    uint256 private constant EIP7702_CODE_SIZE = 23;

    /// @notice Version identifier for substrate lookups
    /// @dev Set to this contract's address at construction, used as key for PreHooksLib.getPreHookSubstrates
    address public immutable VERSION;

    /// @notice Error thrown when an EIP-7702 delegated account has a non-whitelisted delegate target
    /// @param origin The tx.origin address that has the delegation
    /// @param delegateTarget The delegate target address that is not whitelisted
    error InvalidDelegateTarget(address origin, address delegateTarget);

    /// @notice Sets up the VERSION identifier
    constructor() {
        VERSION = address(this);
    }

    /// @notice Executes the pre-hook logic to validate EIP-7702 delegate targets
    /// @dev Checks if tx.origin has an EIP-7702 delegation and validates the delegate target against the whitelist.
    ///      Regular EOAs without delegation are allowed to pass without validation.
    /// @param selector_ The function selector of the main operation that will be executed
    function run(bytes4 selector_) external view {
        address delegateTarget = _getDelegateTarget(tx.origin);

        // Regular EOA without delegation - allow to pass
        if (delegateTarget == address(0)) {
            return;
        }

        // Check whitelist from substrates
        if (!_isWhitelisted(selector_, delegateTarget)) {
            revert InvalidDelegateTarget(tx.origin, delegateTarget);
        }
    }

    /// @notice Extracts the delegate target from an EIP-7702 delegated account
    /// @dev Returns address(0) if:
    ///      - Account code size is not exactly 23 bytes
    ///      - Account code doesn't have the 0xef0100 prefix
    /// @param account_ The account to check for EIP-7702 delegation
    /// @return delegateTarget The delegate target address, or address(0) if not a valid EIP-7702 delegation
    function _getDelegateTarget(address account_) internal view returns (address delegateTarget) {
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(account_)
        }

        // Not an EIP-7702 delegated account if code size is not exactly 23 bytes
        if (codeSize != EIP7702_CODE_SIZE) {
            return address(0);
        }

        bytes memory code = new bytes(EIP7702_CODE_SIZE);
        assembly {
            extcodecopy(account_, add(code, 32), 0, 23)
        }

        // Check for EIP-7702 prefix (0xef0100)
        if (code[0] != 0xef || code[1] != 0x01 || code[2] != 0x00) {
            return address(0);
        }

        // Extract delegate target (last 20 bytes)
        // code starts at position 32 (length prefix), delegate target starts at byte 3
        // So we load from position 32 + 3 = 35 and shift right by 96 bits (12 bytes) to get address
        assembly {
            delegateTarget := shr(96, mload(add(code, 35)))
        }
    }

    /// @notice Checks if a delegate target is whitelisted in substrates
    /// @dev Iterates through substrates configured for this selector and VERSION
    /// @param selector_ The function selector being called
    /// @param target_ The delegate target to check
    /// @return True if the target is whitelisted, false otherwise
    function _isWhitelisted(bytes4 selector_, address target_) internal view returns (bool) {
        bytes32[] memory substrates = PreHooksLib.getPreHookSubstrates(selector_, VERSION);

        uint256 length = substrates.length;
        for (uint256 i; i < length; ++i) {
            if (address(uint160(uint256(substrates[i]))) == target_) {
                return true;
            }
        }

        return false;
    }
}
