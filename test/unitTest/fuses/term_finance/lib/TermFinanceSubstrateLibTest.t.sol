// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {TermFinanceSubstrateType} from "../../../../../contracts/fuses/term_finance/lib/TermFinanceSubstrateLib.sol";
import {TermFinanceSubstrateLibHarness} from "./mocks/TermFinanceSubstrateLibHarness.sol";

/// @title TermFinanceSubstrateLibTest
/// @notice Unit tests for `TermFinanceSubstrateLib`. Targets 100% line and branch coverage
///         of the TYPE-byte substrate encoder/decoder used by every Term Finance fuse.
/// @dev Coverage of the following behaviour. This suite covers:
///       - `collateralPairKey` encoding and TYPE-byte placement
///       - `decodeSubstrateType` for SERVICER, COLLATERAL_TOKEN, and the
///         "fall-open" branch (out-of-range TYPE byte defaults to SERVICER)
///       - `decodeAddress` for both SERVICER (real address) and COLLATERAL_TOKEN
///         (low-160-bits-of-hash, NOT an address — documents the footgun)
///       - `isServicerSubstrate` / `isCollateralTokenSubstrate` predicates on every
///         relevant TYPE byte (0x00, 0x01, and other).
contract TermFinanceSubstrateLibTest is Test {
    // Bit position of the TYPE flag (mirrors the library constant; kept here so the
    // test does not depend on a private library symbol).
    uint256 internal constant FLAG_SHIFT = 248;
    bytes32 internal constant DATA_MASK = bytes32((uint256(1) << FLAG_SHIFT) - 1);

    address internal constant SERVICER_A = address(uint160(0xA11CE));
    address internal constant TOKEN_A = address(uint160(0xB0B));
    address internal constant SERVICER_B = address(uint160(0xCAFE));
    address internal constant TOKEN_B = address(uint160(0xDEAD));

    TermFinanceSubstrateLibHarness internal lib;

    function setUp() public {
        lib = new TermFinanceSubstrateLibHarness();
    }

    // ============================================================
    // collateralPairKey
    // ============================================================

    /// @notice Encoding places TYPE byte 0x01 in the upper byte and the keccak hash
    ///         (truncated to 248 bits) in the lower 31 bytes.
    function test_collateralPairKey_setsTypeByteToOne() public view {
        bytes32 key = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        uint8 typeByte = uint8(uint256(key) >> FLAG_SHIFT);
        assertEq(typeByte, uint8(TermFinanceSubstrateType.COLLATERAL_TOKEN), "type byte must be 0x01");
    }

    /// @notice Lower 248 bits equal the lower 248 bits of `keccak256(abi.encode(servicer, token))`.
    function test_collateralPairKey_dataIsTruncatedKeccak() public view {
        bytes32 key = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        bytes32 expectedFull = keccak256(abi.encode(SERVICER_A, TOKEN_A));
        bytes32 expectedTruncated = expectedFull & DATA_MASK;
        assertEq(key & DATA_MASK, expectedTruncated, "data portion must match truncated keccak");
    }

    /// @notice Swapping servicer and collateral arguments yields a different key (order matters).
    function test_collateralPairKey_distinguishesServicerOrder() public view {
        bytes32 keyAB = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        bytes32 keyBA = lib.collateralPairKey(TOKEN_A, SERVICER_A);
        assertTrue(keyAB != keyBA, "argument order must affect output");
    }

    /// @notice Different (servicer, token) tuples produce different keys. Fuzzed pairwise.
    function testFuzz_collateralPairKey_neverCollides(
        address servicer1,
        address token1,
        address servicer2,
        address token2
    ) public view {
        vm.assume(servicer1 != servicer2 || token1 != token2);
        bytes32 key1 = lib.collateralPairKey(servicer1, token1);
        bytes32 key2 = lib.collateralPairKey(servicer2, token2);
        assertTrue(key1 != key2, "distinct (servicer, token) pairs must encode to distinct keys");
    }

    /// @notice Identical inputs produce identical keys (determinism).
    function testFuzz_collateralPairKey_deterministic(address servicer_, address token_) public view {
        bytes32 first = lib.collateralPairKey(servicer_, token_);
        bytes32 second = lib.collateralPairKey(servicer_, token_);
        assertEq(first, second, "encoding must be deterministic");
    }

    /// @notice Zero addresses are accepted and produce a well-formed COLLATERAL_TOKEN key.
    function test_collateralPairKey_zeroAddresses_stillTypedAsCollateral() public view {
        bytes32 key = lib.collateralPairKey(address(0), address(0));
        assertEq(uint8(uint256(key) >> FLAG_SHIFT), 0x01, "type byte must still be 0x01 for zero inputs");
    }

    // ============================================================
    // decodeSubstrateType
    // ============================================================

    /// @notice TYPE byte 0x00 decodes to SERVICER (the backward-compat default).
    function test_decodeSubstrateType_typeZero_returnsServicer() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A))); // top byte = 0x00
        TermFinanceSubstrateType t = lib.decodeSubstrateType(substrate);
        assertEq(uint8(t), uint8(TermFinanceSubstrateType.SERVICER));
    }

    /// @notice TYPE byte 0x01 decodes to COLLATERAL_TOKEN.
    function test_decodeSubstrateType_typeOne_returnsCollateralToken() public view {
        bytes32 substrate = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        TermFinanceSubstrateType t = lib.decodeSubstrateType(substrate);
        assertEq(uint8(t), uint8(TermFinanceSubstrateType.COLLATERAL_TOKEN));
    }

    /// @notice TYPE byte 0x02 (out-of-range) falls back to SERVICER.
    /// @dev Documents the fall-open behaviour. This is an intentional backward-compat
    ///      choice: legacy `addressToBytes32(servicer)` substrates have TYPE byte 0x00 and
    ///      must decode to SERVICER without migration. Strict callers must use the
    ///      `isServicerSubstrate` / `isCollateralTokenSubstrate` predicates instead.
    function test_decodeSubstrateType_typeTwo_fallsBackToServicer() public view {
        bytes32 substrate = bytes32(uint256(0x02) << FLAG_SHIFT);
        TermFinanceSubstrateType t = lib.decodeSubstrateType(substrate);
        assertEq(uint8(t), uint8(TermFinanceSubstrateType.SERVICER), "unknown TYPE falls open to SERVICER");
    }

    /// @notice TYPE byte 0xFF (max uint8) also falls back to SERVICER.
    function test_decodeSubstrateType_typeMaxByte_fallsBackToServicer() public view {
        bytes32 substrate = bytes32(uint256(0xFF) << FLAG_SHIFT);
        TermFinanceSubstrateType t = lib.decodeSubstrateType(substrate);
        assertEq(uint8(t), uint8(TermFinanceSubstrateType.SERVICER), "0xFF TYPE falls open to SERVICER");
    }

    /// @notice Fuzz the fall-open branch: any TYPE byte > 1 must decode to SERVICER.
    function testFuzz_decodeSubstrateType_outOfRange_fallsBackToServicer(uint8 typeByte, uint248 data) public view {
        vm.assume(typeByte > uint8(type(TermFinanceSubstrateType).max));
        bytes32 substrate = bytes32((uint256(typeByte) << FLAG_SHIFT) | uint256(data));
        TermFinanceSubstrateType t = lib.decodeSubstrateType(substrate);
        assertEq(uint8(t), uint8(TermFinanceSubstrateType.SERVICER));
    }

    // ============================================================
    // decodeAddress
    // ============================================================

    /// @notice For a SERVICER substrate (TYPE 0x00, low 160 bits = address), `decodeAddress`
    ///         returns the original address.
    function test_decodeAddress_servicer_returnsLow160Bits() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)));
        assertEq(lib.decodeAddress(substrate), SERVICER_A);
    }

    /// @notice Fuzz round-trip: any address embedded in the lower 160 bits round-trips.
    function testFuzz_decodeAddress_roundtrip(address account) public view {
        bytes32 substrate = bytes32(uint256(uint160(account)));
        assertEq(lib.decodeAddress(substrate), account);
    }

    /// @notice For a COLLATERAL_TOKEN substrate, `decodeAddress` returns the low 160 bits of
    ///         the truncated keccak hash, NOT a real address. Documents the footgun called
    ///         out in the library NatSpec.
    function test_decodeAddress_collateralToken_returnsHashBits_notRealAddress() public view {
        bytes32 substrate = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        bytes32 fullHash = keccak256(abi.encode(SERVICER_A, TOKEN_A));
        address decoded = lib.decodeAddress(substrate);
        address expected = address(uint160(uint256(fullHash)));
        assertEq(decoded, expected, "decodeAddress on COLLATERAL_TOKEN must return low 160 bits of hash");
        assertTrue(decoded != SERVICER_A, "decoded value must not coincidentally equal the servicer");
        assertTrue(decoded != TOKEN_A, "decoded value must not coincidentally equal the collateral token");
    }

    /// @notice Upper bits above 160 must be ignored by `decodeAddress`.
    function test_decodeAddress_ignoresUpperBits() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)) | (uint256(0xDEADBEEF) << 160));
        assertEq(lib.decodeAddress(substrate), SERVICER_A);
    }

    // ============================================================
    // isServicerSubstrate
    // ============================================================

    function test_isServicerSubstrate_typeZero_returnsTrue() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)));
        assertTrue(lib.isServicerSubstrate(substrate));
    }

    function test_isServicerSubstrate_typeOne_returnsFalse() public view {
        bytes32 substrate = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        assertFalse(lib.isServicerSubstrate(substrate));
    }

    function test_isServicerSubstrate_typeOutOfRange_returnsFalse() public view {
        // TYPE byte 0x02 is not SERVICER (even though `decodeSubstrateType` falls back).
        // `isServicerSubstrate` is the STRICT predicate — checks raw TYPE byte equality.
        bytes32 substrate = bytes32(uint256(0x02) << FLAG_SHIFT);
        assertFalse(lib.isServicerSubstrate(substrate));
    }

    function test_isServicerSubstrate_typeMaxByte_returnsFalse() public view {
        bytes32 substrate = bytes32(uint256(0xFF) << FLAG_SHIFT);
        assertFalse(lib.isServicerSubstrate(substrate));
    }

    /// @notice STRICT predicate — a substrate with TYPE byte 0x00 but dirt in
    ///         bits 247..160 (which `decodeAddress` would silently truncate) is NOT a valid
    ///         SERVICER substrate. Only `addressToBytes32(servicer)` (clean upper 96 bits)
    ///         qualifies, so this returns false.
    function test_isServicerSubstrate_typeZeroWithDirtyData_returnsFalse() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)) | (uint256(0xCAFE) << 160));
        assertFalse(lib.isServicerSubstrate(substrate));
    }

    /// @notice A clean `addressToBytes32(servicer)` substrate (upper 96 bits zero)
    ///         still classifies as SERVICER — backward compatibility preserved.
    function test_isServicerSubstrate_cleanAddress_returnsTrue() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)));
        assertTrue(lib.isServicerSubstrate(substrate));
    }

    // ============================================================
    // isCollateralTokenSubstrate
    // ============================================================

    function test_isCollateralTokenSubstrate_typeOne_returnsTrue() public view {
        bytes32 substrate = lib.collateralPairKey(SERVICER_A, TOKEN_A);
        assertTrue(lib.isCollateralTokenSubstrate(substrate));
    }

    function test_isCollateralTokenSubstrate_typeZero_returnsFalse() public view {
        bytes32 substrate = bytes32(uint256(uint160(SERVICER_A)));
        assertFalse(lib.isCollateralTokenSubstrate(substrate));
    }

    function test_isCollateralTokenSubstrate_typeOutOfRange_returnsFalse() public view {
        bytes32 substrate = bytes32(uint256(0x02) << FLAG_SHIFT);
        assertFalse(lib.isCollateralTokenSubstrate(substrate));
    }

    function test_isCollateralTokenSubstrate_typeMaxByte_returnsFalse() public view {
        bytes32 substrate = bytes32(uint256(0xFF) << FLAG_SHIFT);
        assertFalse(lib.isCollateralTokenSubstrate(substrate));
    }

    // ============================================================
    // Predicates and decoder agree on encoded outputs (cross-check)
    // ============================================================

    /// @notice For a freshly-encoded COLLATERAL_TOKEN substrate, predicates and decoder agree.
    function testFuzz_collateralPair_predicatesAgree(address servicer_, address token_) public view {
        bytes32 substrate = lib.collateralPairKey(servicer_, token_);
        assertTrue(lib.isCollateralTokenSubstrate(substrate));
        assertFalse(lib.isServicerSubstrate(substrate));
        assertEq(uint8(lib.decodeSubstrateType(substrate)), uint8(TermFinanceSubstrateType.COLLATERAL_TOKEN));
    }

    /// @notice For a legacy `addressToBytes32(servicer)` substrate (TYPE 0x00), predicates
    ///         and decoder agree on SERVICER.
    function testFuzz_servicerSubstrate_predicatesAgree(address servicer_) public view {
        bytes32 substrate = bytes32(uint256(uint160(servicer_)));
        assertTrue(lib.isServicerSubstrate(substrate));
        assertFalse(lib.isCollateralTokenSubstrate(substrate));
        assertEq(uint8(lib.decodeSubstrateType(substrate)), uint8(TermFinanceSubstrateType.SERVICER));
        assertEq(lib.decodeAddress(substrate), servicer_);
    }
}
