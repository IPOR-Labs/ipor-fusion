// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {EulerFuseLib} from "../../../contracts/fuses/euler/EulerFuseLib.sol";

/// @title EulerFuseLibTest
/// @dev Test contract for EulerFuseLib.generateSubAccountAddress function
contract EulerFuseLibTest is Test {
    /// @notice Test that generateSubAccountAddress produces the correct result using XOR operation
    function test_generateSubAccountAddress_BasicXOR() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountId = 0x01;

        address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "Sub-account address should match XOR calculation");
    }

    /// @notice Test with zero sub-account ID
    function test_generateSubAccountAddress_ZeroSubAccount() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountId = 0x00;

        address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "Sub-account address with zero ID should match XOR calculation");
        assertEq(result, plasmaVault, "Sub-account address with zero ID should equal original address");
    }

    /// @notice Test with maximum sub-account ID (0xFF)
    function test_generateSubAccountAddress_MaxSubAccount() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountId = 0xFF;

        address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "Sub-account address with max ID should match XOR calculation");
    }

    /// @notice Test that XOR operation is reversible
    function test_generateSubAccountAddress_XORReversible() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountId = 0x42;

        address subAccount = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        // XOR the sub-account with the sub-account ID should give back the original plasma vault
        address recovered = address(uint160(subAccount) ^ uint160(uint8(subAccountId)));
        assertEq(recovered, plasmaVault, "XOR operation should be reversible");
    }

    /// @notice Test with different plasma vault addresses
    function test_generateSubAccountAddress_DifferentVaults() public {
        bytes1 subAccountId = 0x01;

        address[] memory vaults = new address[](3);
        vaults[0] = address(0); // Zero address
        vaults[1] = 0x1111111111111111111111111111111111111111; // Pattern address
        vaults[2] = 0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF; // Max address

        for (uint256 i = 0; i < vaults.length; i++) {
            address expected = address(uint160(vaults[i]) ^ uint160(uint8(subAccountId)));
            address result = EulerFuseLib.generateSubAccountAddress(vaults[i], subAccountId);

            assertEq(result, expected, "Sub-account address should match XOR calculation for different vaults");
        }
    }

    /// @notice Test with different sub-account IDs
    function test_generateSubAccountAddress_DifferentSubAccounts() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;

        bytes1[] memory subAccountIds = new bytes1[](8);
        subAccountIds[0] = 0x00;
        subAccountIds[1] = 0x01;
        subAccountIds[2] = 0x0F;
        subAccountIds[3] = 0x10;
        subAccountIds[4] = 0x42;
        subAccountIds[5] = 0x7F;
        subAccountIds[6] = 0x80;
        subAccountIds[7] = 0xFF;

        for (uint256 i = 0; i < subAccountIds.length; i++) {
            address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountIds[i])));
            address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountIds[i]);

            assertEq(
                result,
                expected,
                "Sub-account address should match XOR calculation for different sub-account IDs"
            );
        }
    }

    /// @notice Test that different sub-account IDs produce different addresses
    function test_generateSubAccountAddress_UniqueAddresses() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;

        address[] memory generatedAddresses = new address[](256);

        // Generate addresses for all possible sub-account IDs (0x00 to 0xFF)
        for (uint256 i = 0; i < 256; i++) {
            bytes1 subAccountId = bytes1(uint8(i));
            generatedAddresses[i] = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);
        }

        // Check that all addresses are unique
        for (uint256 i = 0; i < 256; i++) {
            for (uint256 j = i + 1; j < 256; j++) {
                assertTrue(
                    generatedAddresses[i] != generatedAddresses[j],
                    "Different sub-account IDs should produce different addresses"
                );
            }
        }
    }

    /// @notice Test that the same sub-account ID with different vaults produces different addresses
    function test_generateSubAccountAddress_DifferentVaultsSameSubAccount() public {
        bytes1 subAccountId = 0x42;

        address vault1 = 0x1111111111111111111111111111111111111111;
        address vault2 = 0x2222222222222222222222222222222222222222;

        address subAccount1 = EulerFuseLib.generateSubAccountAddress(vault1, subAccountId);
        address subAccount2 = EulerFuseLib.generateSubAccountAddress(vault2, subAccountId);

        assertTrue(
            subAccount1 != subAccount2,
            "Different vaults with same sub-account ID should produce different addresses"
        );
    }

    /// @notice Test with real-world example addresses
    function test_generateSubAccountAddress_RealWorldExample() public {
        // Example from the existing test file
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountByteOne = 0x01;
        bytes1 subAccountByteTwo = 0x02;

        address subAccountOne = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountByteOne);
        address subAccountTwo = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountByteTwo);

        // Verify they are different
        assertTrue(subAccountOne != subAccountTwo, "Different sub-account IDs should produce different addresses");

        // Verify they match XOR calculation
        assertEq(
            subAccountOne,
            address(uint160(plasmaVault) ^ uint160(uint8(subAccountByteOne))),
            "Sub-account one should match XOR calculation"
        );

        assertEq(
            subAccountTwo,
            address(uint160(plasmaVault) ^ uint160(uint8(subAccountByteTwo))),
            "Sub-account two should match XOR calculation"
        );
    }

    /// @notice Test edge case with zero address vault
    function test_generateSubAccountAddress_ZeroAddressVault() public {
        address plasmaVault = address(0);
        bytes1 subAccountId = 0x01;

        address expected = address(uint160(plasmaVault) ^ uint160(uint8(subAccountId)));
        address result = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        assertEq(result, expected, "Zero address vault should work correctly");
        assertEq(
            result,
            address(uint160(uint8(subAccountId))),
            "Zero address vault with sub-account should equal sub-account ID"
        );
    }

    /// @notice Test that the function is pure and doesn't modify state
    function test_generateSubAccountAddress_PureFunction() public {
        address plasmaVault = 0x1234567890123456789012345678901234567890;
        bytes1 subAccountId = 0x42;

        // Call the function multiple times with same inputs
        address result1 = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);
        address result2 = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);
        address result3 = EulerFuseLib.generateSubAccountAddress(plasmaVault, subAccountId);

        // All results should be identical
        assertEq(result1, result2, "Pure function should return same result for same inputs");
        assertEq(result2, result3, "Pure function should return same result for same inputs");
    }
}
