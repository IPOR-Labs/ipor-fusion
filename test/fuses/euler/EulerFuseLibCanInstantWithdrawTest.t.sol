// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @title EulerFuseLibCanInstantWithdrawTest
/// @notice Unit tests for EulerFuseLib.canInstantWithdraw() function
contract EulerFuseLibCanInstantWithdrawTest is Test {
    // ============ Constants ============

    uint256 public constant MARKET_ID = 1;
    address public constant EULER_VAULT_1 = address(0x1111);
    address public constant EULER_VAULT_2 = address(0x2222);
    bytes1 public constant SUB_ACCOUNT_1 = 0x01;
    bytes1 public constant SUB_ACCOUNT_2 = 0x02;

    // ============ Setup ============

    function setUp() public {
        vm.label(EULER_VAULT_1, "EulerVault1");
        vm.label(EULER_VAULT_2, "EulerVault2");
    }

    // ============ canInstantWithdraw Tests - Success Cases ============

    function testCanInstantWithdrawReturnsTrueWhenBothFlagsFalse() public {
        // given - Setup substrate with isCollateral=false, canBorrow=false
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, false, false);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then
        assertTrue(result, "Should return true when both flags are false");
    }

    function testCanInstantWithdrawWithMultipleSubstratesFindsCorrectOne() public {
        // given - Setup multiple substrates, only one eligible for instant withdraw
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, true, false); // Not eligible
        _setupSubstrate(EULER_VAULT_2, SUB_ACCOUNT_1, false, true); // Not eligible
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_2, false, false); // Eligible

        // when
        bool result1 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);
        bool result2 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_2, SUB_ACCOUNT_1);
        bool result3 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_2);

        // then
        assertFalse(result1, "Should return false when isCollateral=true");
        assertFalse(result2, "Should return false when canBorrow=true");
        assertTrue(result3, "Should return true for eligible substrate");
    }

    // ============ canInstantWithdraw Tests - Failure Cases ============

    function testCanInstantWithdrawReturnsFalseWhenIsCollateralTrue() public {
        // given - Setup substrate with isCollateral=true
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, true, false);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then
        assertFalse(result, "Should return false when isCollateral is true");
    }

    function testCanInstantWithdrawReturnsFalseWhenCanBorrowTrue() public {
        // given - Setup substrate with canBorrow=true
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, false, true);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then
        assertFalse(result, "Should return false when canBorrow is true");
    }

    function testCanInstantWithdrawReturnsFalseWhenBothFlagsTrue() public {
        // given - Setup substrate with both flags true
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, true, true);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then
        assertFalse(result, "Should return false when both flags are true");
    }

    function testCanInstantWithdrawReturnsFalseWhenVaultNotFound() public {
        // given - Setup substrate for different vault
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, false, false);

        // when - Query for non-existent vault
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_2, SUB_ACCOUNT_1);

        // then
        assertFalse(result, "Should return false when vault not found");
    }

    function testCanInstantWithdrawReturnsFalseWhenSubAccountNotMatched() public {
        // given - Setup substrate for SUB_ACCOUNT_1
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, false, false);

        // when - Query for different sub-account
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_2);

        // then
        assertFalse(result, "Should return false when sub-account doesn't match");
    }

    function testCanInstantWithdrawReturnsFalseWhenMarketHasNoSubstrates() public {
        // given - No substrates configured for market

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then
        assertFalse(result, "Should return false when market has no substrates");
    }

    // ============ Fuzz Tests ============

    function testFuzzCanInstantWithdrawWithVariousAddresses(
        address vault,
        bytes1 subAccount,
        bool isCollateral,
        bool canBorrow
    ) public {
        // given
        vm.assume(vault != address(0)); // Avoid zero address
        _setupSubstrate(vault, subAccount, isCollateral, canBorrow);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, vault, subAccount);

        // then - Should only return true when both flags are false
        if (!isCollateral && !canBorrow) {
            assertTrue(result, "Should return true when both flags false");
        } else {
            assertFalse(result, "Should return false when any flag is true");
        }
    }

    // ============ Edge Cases ============

    function testCanInstantWithdrawWithZeroSubAccount() public {
        // given - Setup substrate with zero sub-account
        bytes1 zeroSubAccount = 0x00;
        _setupSubstrate(EULER_VAULT_1, zeroSubAccount, false, false);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, zeroSubAccount);

        // then
        assertTrue(result, "Should work with zero sub-account");
    }

    function testCanInstantWithdrawWithMaxSubAccount() public {
        // given - Setup substrate with max sub-account value
        bytes1 maxSubAccount = 0xFF;
        _setupSubstrate(EULER_VAULT_1, maxSubAccount, false, false);

        // when
        bool result = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, maxSubAccount);

        // then
        assertTrue(result, "Should work with max sub-account value");
    }

    function testCanInstantWithdrawIsPureAndDeterministic() public {
        // given - Setup substrate
        _setupSubstrate(EULER_VAULT_1, SUB_ACCOUNT_1, false, false);

        // when - Call multiple times
        bool result1 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);
        bool result2 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);
        bool result3 = EulerFuseLib.canInstantWithdraw(MARKET_ID, EULER_VAULT_1, SUB_ACCOUNT_1);

        // then - All results should be identical
        assertEq(result1, result2, "Results should be deterministic");
        assertEq(result2, result3, "Results should be deterministic");
    }

    // ============ Helper Functions ============

    /// @notice Setup a substrate configuration in storage
    /// @param vault_ The Euler vault address
    /// @param subAccount_ The sub-account identifier
    /// @param isCollateral_ Whether vault can be used as collateral
    /// @param canBorrow_ Whether one can borrow against it
    function _setupSubstrate(address vault_, bytes1 subAccount_, bool isCollateral_, bool canBorrow_) internal {
        // Create substrate
        EulerSubstrate memory substrate = EulerSubstrate({
            eulerVault: vault_,
            isCollateral: isCollateral_,
            canBorrow: canBorrow_,
            subAccounts: subAccount_
        });

        // Convert to bytes32
        bytes32 substrateBytes = EulerFuseLib.substrateToBytes32(substrate);

        // Get existing substrates
        PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates = PlasmaVaultStorageLib
            .getMarketSubstrates()
            .value[MARKET_ID];

        bytes32[] memory existingSubstrates = marketSubstrates.substrates;
        uint256 existingLength = existingSubstrates.length;

        // Create new array with one more element
        bytes32[] memory newSubstrates = new bytes32[](existingLength + 1);

        // Copy existing substrates
        for (uint256 i; i < existingLength; ) {
            newSubstrates[i] = existingSubstrates[i];
            unchecked {
                ++i;
            }
        }

        // Add new substrate
        newSubstrates[existingLength] = substrateBytes;

        // Update storage
        marketSubstrates.substrates = newSubstrates;
        marketSubstrates.substrateAllowances[substrateBytes] = 1;
    }
}
