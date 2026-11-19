// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultStorageLib} from "../../../contracts/libraries/PlasmaVaultStorageLib.sol";

/// @title EulerFuseLibSwapPoolSubstrateTest
/// @notice IL-9706: layout, round trip and lookup of EulerSwap pool entries
contract EulerFuseLibSwapPoolSubstrateTest is Test {
    uint256 internal constant MARKET_ID = 11;
    address internal constant POOL = address(0x9999);
    address internal constant OTHER_POOL = address(0x8888);
    bytes1 internal constant SUB = 0x01;
    bytes1 internal constant OTHER_SUB = 0x02;

    function _grant(bytes32 entry_) internal {
        PlasmaVaultStorageLib.MarketSubstratesStruct storage m = PlasmaVaultStorageLib.getMarketSubstrates().value[
            MARKET_ID
        ];
        m.substrates.push(entry_);
        m.substrateAllowances[entry_] = 1;
    }

    function testLayoutPinned() public pure {
        bytes32 expected = bytes32((uint256(uint160(POOL)) << 96) | (uint256(0x01) << 72) | (uint256(0x01) << 64));
        assertEq(EulerFuseLib.swapPoolSubstrateToBytes32(POOL, SUB), expected, "layout");
        // pool address in the top 160 bits, flag bytes (bits 80-95) zero, kind byte (bits 64-71) = 1, padding zero
        uint256 raw = uint256(expected);
        assertEq(address(uint160(raw >> 96)), POOL);
        assertEq(uint16(raw >> 80), 0, "flag bytes zero");
        assertEq(uint8(raw >> 72), 0x01, "sub-account byte");
        assertEq(uint8(raw >> 64), 0x01, "kind byte");
        assertEq(uint64(raw), 0, "padding zero");
    }

    function testRoundTrip() public pure {
        bytes32 entry = EulerFuseLib.swapPoolSubstrateToBytes32(POOL, OTHER_SUB);
        assertTrue(EulerFuseLib.isSwapPoolSubstrate(entry));
        (address pool, bytes1 sub) = EulerFuseLib.bytes32ToSwapPoolSubstrate(entry);
        assertEq(pool, POOL);
        assertEq(sub, OTHER_SUB);
    }

    function testFuzzRoundTrip(address pool_, bytes1 sub_) public pure {
        bytes32 entry = EulerFuseLib.swapPoolSubstrateToBytes32(pool_, sub_);
        assertTrue(EulerFuseLib.isSwapPoolSubstrate(entry));
        (address pool, bytes1 sub) = EulerFuseLib.bytes32ToSwapPoolSubstrate(entry);
        assertEq(pool, pool_);
        assertEq(sub, sub_);
    }

    function testEncoderZeroesFlagBytes() public pure {
        uint256 raw = uint256(EulerFuseLib.swapPoolSubstrateToBytes32(address(type(uint160).max), 0xff));
        assertEq(uint16(raw >> 80), 0);
    }

    function testEVaultEntriesAreNotPoolEntries() public pure {
        bytes32 entry = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({eulerVault: POOL, isCollateral: true, canBorrow: true, subAccounts: 0xff})
        );
        assertFalse(EulerFuseLib.isSwapPoolSubstrate(entry));
    }

    function testEntryWithFlagBytesStillPoolEntry() public pure {
        bytes32 entry = bytes32(
            (uint256(uint160(POOL)) << 96) |
                (uint256(1) << 88) |
                (uint256(1) << 80) |
                (uint256(0x01) << 72) |
                (uint256(1) << 64)
        );
        assertTrue(EulerFuseLib.isSwapPoolSubstrate(entry));
        (address pool, bytes1 sub) = EulerFuseLib.bytes32ToSwapPoolSubstrate(entry);
        assertEq(pool, POOL);
        assertEq(sub, SUB);
    }

    function testIsSwapPoolGrantedExactPair() public {
        _grant(EulerFuseLib.swapPoolSubstrateToBytes32(POOL, SUB));
        assertTrue(EulerFuseLib.isSwapPoolGranted(MARKET_ID, POOL, SUB));
        assertFalse(EulerFuseLib.isSwapPoolGranted(MARKET_ID, POOL, OTHER_SUB), "other sub-account");
        assertFalse(EulerFuseLib.isSwapPoolGranted(MARKET_ID, OTHER_POOL, SUB), "other pool");
        assertFalse(EulerFuseLib.isSwapPoolGranted(MARKET_ID + 1, POOL, SUB), "other market");
    }

    function testIsSwapPoolGrantedIgnoresEVaultEntry() public {
        _grant(
            EulerFuseLib.substrateToBytes32(
                EulerSubstrate({eulerVault: POOL, isCollateral: false, canBorrow: false, subAccounts: SUB})
            )
        );
        assertFalse(EulerFuseLib.isSwapPoolGranted(MARKET_ID, POOL, SUB));
    }

    function testIsSwapPoolGrantedFindsEntryAmongOthers() public {
        _grant(EulerFuseLib.swapPoolSubstrateToBytes32(OTHER_POOL, SUB));
        _grant(
            EulerFuseLib.substrateToBytes32(
                EulerSubstrate({eulerVault: POOL, isCollateral: false, canBorrow: false, subAccounts: SUB})
            )
        );
        _grant(EulerFuseLib.swapPoolSubstrateToBytes32(POOL, SUB));
        assertTrue(EulerFuseLib.isSwapPoolGranted(MARKET_ID, POOL, SUB));
    }

    function testFlaggedPoolEntryIsSkippedByCapabilityChecks() public {
        _grant(
            bytes32(
                (uint256(uint160(POOL)) << 96) |
                    (uint256(1) << 88) |
                    (uint256(1) << 80) |
                    (uint256(0x01) << 72) |
                    (uint256(1) << 64)
            )
        );
        assertFalse(EulerFuseLib.canSupply(MARKET_ID, POOL, SUB));
        assertFalse(EulerFuseLib.canCollateral(MARKET_ID, POOL, SUB));
        assertFalse(EulerFuseLib.canBorrow(MARKET_ID, POOL, SUB));
        assertFalse(EulerFuseLib.canInstantWithdraw(MARKET_ID, POOL, SUB));
        assertFalse(EulerFuseLib.isEulerVaultGranted(MARKET_ID, POOL));
    }

    function testPoolEntryDoesNotBlockInstantWithdrawOfSameAddressEVaultRow() public {
        _grant(EulerFuseLib.swapPoolSubstrateToBytes32(POOL, SUB));
        _grant(
            EulerFuseLib.substrateToBytes32(
                EulerSubstrate({eulerVault: POOL, isCollateral: false, canBorrow: false, subAccounts: SUB})
            )
        );
        assertTrue(EulerFuseLib.canSupply(MARKET_ID, POOL, SUB));
        assertTrue(EulerFuseLib.canInstantWithdraw(MARKET_ID, POOL, SUB));
        assertTrue(EulerFuseLib.isEulerVaultGranted(MARKET_ID, POOL));
    }
}
