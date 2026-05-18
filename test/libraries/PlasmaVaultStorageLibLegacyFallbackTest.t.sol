// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @title PlasmaVaultStorageLibLegacyFallbackTest
/// @notice Unit tests for getWithdrawManagerAddressWithLegacyFallback() introduced in IL-7407.
contract PlasmaVaultStorageLibLegacyFallbackTest is Test {
    /// @dev New (correct, IL-6952) slot used by getWithdrawManager().manager
    bytes32 private constant WITHDRAW_MANAGER_NEW_SLOT =
        0x465d2ff0062318fe6f4c7e9ac78cfcd70bc86a1d992722875ef83a9770513100;

    /// @dev Legacy slot used by pre-IL-6952 deployed PlasmaVaults
    bytes32 private constant WITHDRAW_MANAGER_LEGACY_SLOT =
        0xb37e8684757599da669b8aea811ee2b3693b2582d2c730fab3f4965fa2ec3e11;

    /// @notice Convenience wrapper that calls the IL-7407 helper. Library is `internal`
    ///         so the call is inlined and reads THIS contract's storage — that's why
    ///         `vm.store(address(this), ...)` works.
    function _read() internal view returns (address) {
        return PlasmaVaultStorageLib.getWithdrawManagerAddressWithLegacyFallback();
    }

    function testReturnsNewSlot_whenOnlyNewSlotIsSet() external {
        address expected = address(0xABCD);
        vm.store(address(this), WITHDRAW_MANAGER_NEW_SLOT, bytes32(uint256(uint160(expected))));
        assertEq(_read(), expected, "must return new slot value");
    }

    function testPrefersNewSlot_overLegacy() external {
        address newVal = address(0xABCD);
        address legacyVal = address(0xDEAD);
        vm.store(address(this), WITHDRAW_MANAGER_NEW_SLOT, bytes32(uint256(uint160(newVal))));
        vm.store(address(this), WITHDRAW_MANAGER_LEGACY_SLOT, bytes32(uint256(uint160(legacyVal))));
        assertEq(_read(), newVal, "new slot must win over legacy");
    }

    function testFallsBackToLegacySlot_whenNewSlotIsZero() external {
        address expected = address(0xDEAD);
        vm.store(address(this), WITHDRAW_MANAGER_LEGACY_SLOT, bytes32(uint256(uint160(expected))));
        assertEq(_read(), expected, "must fall back to legacy slot");
    }

    function testReturnsZero_whenBothSlotsAreZero() external view {
        assertEq(_read(), address(0), "must return zero when neither slot is set");
    }
}
