// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EulerFuseLib} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @title EulerFuseLibSwapPoolSubstrateRegressionTest
/// @notice IL-9706: a market-11 entry for an EulerSwap pool (kind byte after the sub-account byte, bit 64 set) must be
///         skipped by every capability check of EulerFuseLib. The entries are raw bytes32 values, so this file compiles
///         on the base commit, where the kind byte is ignored and the pool address is read as an eVault.
///         Each comment "base: X" is the result on the base commit 69766843; each test targets one function.
contract EulerFuseLibSwapPoolSubstrateRegressionTest is Test {
    uint256 internal constant MARKET_ID = 11;
    address internal constant POOL = address(0x9999);
    address internal constant EVAULT = address(0x1111);
    bytes1 internal constant SUB = 0x01;

    /// @dev Raw layout: [160 address][isCollateral byte][canBorrow byte][sub-account byte][kind byte][64 padding]
    function _rawEntry(
        address target_,
        bool isCollateral_,
        bool canBorrow_,
        bytes1 sub_,
        uint8 kind_
    ) internal pure returns (bytes32) {
        return
            bytes32(
                (uint256(uint160(target_)) << 96) |
                    (uint256(isCollateral_ ? 1 : 0) << 88) |
                    (uint256(canBorrow_ ? 1 : 0) << 80) |
                    (uint256(uint8(sub_)) << 72) |
                    (uint256(kind_) << 64)
            );
    }

    function _grant(bytes32 entry_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage m = PlasmaVaultStorageLib.getMarketSubstrates().value[
            MARKET_ID
        ];
        m.substrates.push(entry_);
        m.substrateAllowances[entry_] = 1;
    }

    // ---- pool entry without flag bytes (proves canSupply, canInstantWithdraw, isEulerVaultGranted)

    function testCanSupplySkipsUnflaggedPoolEntry() public {
        _grant(_rawEntry(POOL, false, false, SUB, 1));
        // base: true (the pool address is read as an eVault)
        assertFalse(EulerFuseLib.canSupply(MARKET_ID, POOL, SUB), "pool entry must not count as a supply target");
    }

    function testCanInstantWithdrawSkipsUnflaggedPoolEntry() public {
        _grant(_rawEntry(POOL, false, false, SUB, 1));
        // base: true
        assertFalse(
            EulerFuseLib.canInstantWithdraw(MARKET_ID, POOL, SUB),
            "pool entry must not count as an instant-withdraw target"
        );
    }

    function testIsEulerVaultGrantedSkipsUnflaggedPoolEntry() public {
        _grant(_rawEntry(POOL, false, false, SUB, 1));
        // base: true
        assertFalse(EulerFuseLib.isEulerVaultGranted(MARKET_ID, POOL), "pool entry must not count as a granted eVault");
    }

    // ---- pool entry with both flag bytes set (proves canCollateral and canBorrow)

    function testCanCollateralSkipsFlaggedPoolEntry() public {
        _grant(_rawEntry(POOL, true, true, SUB, 1));
        // base: true
        assertFalse(EulerFuseLib.canCollateral(MARKET_ID, POOL, SUB), "pool entry must not enable collateral");
    }

    function testCanBorrowSkipsFlaggedPoolEntry() public {
        _grant(_rawEntry(POOL, true, true, SUB, 1));
        // base: true
        assertFalse(EulerFuseLib.canBorrow(MARKET_ID, POOL, SUB), "pool entry must not enable borrowing");
    }

    /// @dev Control, not a proof: false on both revisions (the flags block instant withdraw on the base)
    function testCanInstantWithdrawFlaggedPoolEntryIsFalseOnBothRevisions() public {
        _grant(_rawEntry(POOL, true, true, SUB, 1));
        // base: false
        assertFalse(EulerFuseLib.canInstantWithdraw(MARKET_ID, POOL, SUB));
    }

    // ---- controls: ordinary eVault rows keep their results

    function testOrdinaryEVaultRowsUnchanged() public {
        _grant(_rawEntry(EVAULT, true, true, SUB, 0));
        // base: all true
        assertTrue(EulerFuseLib.canSupply(MARKET_ID, EVAULT, SUB));
        assertTrue(EulerFuseLib.canCollateral(MARKET_ID, EVAULT, SUB));
        assertTrue(EulerFuseLib.canBorrow(MARKET_ID, EVAULT, SUB));
        assertTrue(EulerFuseLib.isEulerVaultGranted(MARKET_ID, EVAULT));
        // base: false (flags block instant withdraw)
        assertFalse(EulerFuseLib.canInstantWithdraw(MARKET_ID, EVAULT, SUB));
    }

    function testOrdinaryUnflaggedEVaultRowCanInstantWithdraw() public {
        _grant(_rawEntry(EVAULT, false, false, SUB, 0));
        // base: true
        assertTrue(EulerFuseLib.canInstantWithdraw(MARKET_ID, EVAULT, SUB));
    }

    function testEVaultRowAndPoolEntryOnSameSubAccount() public {
        _grant(_rawEntry(EVAULT, false, false, SUB, 0));
        _grant(_rawEntry(POOL, false, false, SUB, 1));
        // the eVault row keeps working on both revisions
        assertTrue(EulerFuseLib.canSupply(MARKET_ID, EVAULT, SUB));
        assertTrue(EulerFuseLib.canInstantWithdraw(MARKET_ID, EVAULT, SUB));
        assertTrue(EulerFuseLib.isEulerVaultGranted(MARKET_ID, EVAULT));
    }
}
