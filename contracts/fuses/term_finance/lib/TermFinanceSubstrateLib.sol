// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

/// @title TermFinanceSubstrateType
/// @notice Type flag for Term Finance substrate encoding.
/// @dev Stored in the most significant byte (bits 255..248) of the bytes32 substrate.
///      `SERVICER` is value 0 so that legacy `addressToBytes32(servicer)` substrates
///      (which have upper byte 0x00) decode to `SubstrateType.SERVICER` without migration.
///      This is the load-bearing backward-compatibility property: AaveV4SubstrateLib uses
///      `Undefined = 0` to fail-closed on uninitialized substrates, but Term Finance
///      cannot do that — there are already SERVICER substrates with upper byte 0x00 in
///      production storage.
enum TermFinanceSubstrateType {
    /// @dev 0x00 - TermRepoServicer address (backward-compatible with lender-side
    ///      `addressToBytes32(servicer)` substrates).
    SERVICER,
    /// @dev 0x01 - (servicer, collateralToken) pair key produced by
    ///      `TermFinanceSubstrateLib.collateralPairKey`.
    COLLATERAL_TOKEN
}

/// @title TermFinanceSubstrateLib
/// @author IPOR Labs
/// @notice Encoding and decoding of typed substrates for Term Finance integration.
/// @dev Substrate layout (bytes32):
///      +----------+---------------------------+---------------------+
///      | Bits     | 255..248 (8 bits)         | 247..0 (248 bits)   |
///      +----------+---------------------------+---------------------+
///      | Content  | Type flag (uint8)         | Data (248 bits)     |
///      +----------+---------------------------+---------------------+
///      SERVICER:         data = address in low 160 bits; bits 247..160 = 0
///                        (matches `PlasmaVaultConfigLib.addressToBytes32` output).
///      COLLATERAL_TOKEN: data = keccak256(abi.encode(servicer, collateralToken))
///                        truncated to 248 bits.
///
///      Layout mirrors `AaveV4SubstrateLib._TYPE_SHIFT = 248` exactly.
library TermFinanceSubstrateLib {
    /// @notice Bit position of the type flag byte (top byte of the bytes32 substrate).
    uint256 internal constant _FLAG_SHIFT = 248;

    /// @dev Mask for the low 248 bits (the data portion of the substrate).
    bytes32 private constant _DATA_MASK = bytes32((uint256(1) << _FLAG_SHIFT) - 1);

    /// @notice Encode a `(servicer, collateralToken)` pair as a `COLLATERAL_TOKEN` substrate.
    /// @dev Upper byte = 0x01 (TYPE), lower 31 bytes = `keccak256(abi.encode(servicer, token))`
    ///      truncated to 248 bits. The 248-bit truncated keccak space (2^248) makes accidental
    ///      collision computationally infeasible. The TYPE byte makes the encoding disjoint
    ///      from `addressToBytes32` (TYPE 0x00).
    /// @param servicer_ TermRepoServicer proxy address paired with the collateral.
    /// @param collateralToken_ Allowlisted collateral token address.
    /// @return Encoded `COLLATERAL_TOKEN` substrate.
    function collateralPairKey(address servicer_, address collateralToken_) internal pure returns (bytes32) {
        bytes32 data = keccak256(abi.encode(servicer_, collateralToken_));
        return bytes32(uint256(TermFinanceSubstrateType.COLLATERAL_TOKEN) << _FLAG_SHIFT) | (data & _DATA_MASK);
    }

    /// @notice Decode the type flag from a substrate.
    /// @dev Defaults to `SERVICER` on an out-of-range type byte to preserve backward
    ///      compatibility with legacy `addressToBytes32` substrates (whose upper byte is
    ///      0x00 and would decode to `SERVICER` naturally). Strict callers should use the
    ///      `isServicerSubstrate` / `isCollateralTokenSubstrate` predicates.
    /// @param substrate_ Encoded bytes32 substrate.
    /// @return The decoded `TermFinanceSubstrateType`.
    function decodeSubstrateType(bytes32 substrate_) internal pure returns (TermFinanceSubstrateType) {
        uint8 flag = uint8(uint256(substrate_) >> _FLAG_SHIFT);
        if (flag > uint8(type(TermFinanceSubstrateType).max)) {
            return TermFinanceSubstrateType.SERVICER;
        }
        return TermFinanceSubstrateType(flag);
    }

    /// @notice Decode the address payload from a substrate.
    /// @dev Returns the low 160 bits of the substrate. Meaningful only for `SERVICER`
    ///      substrates (where the data byte holds an address). For `COLLATERAL_TOKEN`
    ///      substrates the result is a truncated keccak hash, NOT an address — callers
    ///      MUST filter by `isServicerSubstrate(raw)` before invoking this helper.
    /// @param substrate_ Encoded bytes32 substrate.
    /// @return The decoded address (lower 160 bits).
    function decodeAddress(bytes32 substrate_) internal pure returns (address) {
        return address(uint160(uint256(substrate_)));
    }

    /// @notice True iff the substrate bytes32 has TYPE byte 0x00 (= `SERVICER`).
    /// @dev Used by the balance fuse to distinguish servicer substrates from collateral
    ///      pair keys when iterating the unified substrate list.
    /// @dev STRICT predicate — a `SERVICER` substrate is exactly
    ///      `addressToBytes32(servicer)`, i.e. the ENTIRE upper 96 bits (255..160) are zero,
    ///      not merely the TYPE byte. Checking only the TYPE byte would accept a hand-crafted
    ///      substrate with `0x00` in bits 255..248 but dirt in bits 247..160, which
    ///      `decodeAddress` would then silently truncate to a different address. The strict
    ///      check stays disjoint from `COLLATERAL_TOKEN` (TYPE byte 0x01 → upper bits non-zero)
    ///      and from any future TYPE, and a legitimate `addressToBytes32` substrate (clean
    ///      upper bits) still returns true so backward compatibility is preserved.
    /// @param raw_ Encoded bytes32 substrate.
    /// @return True if `raw_` encodes a `SERVICER` substrate.
    function isServicerSubstrate(bytes32 raw_) internal pure returns (bool) {
        return (uint256(raw_) >> 160) == 0;
    }

    /// @notice True iff the substrate bytes32 has TYPE byte 0x01 (= `COLLATERAL_TOKEN`).
    /// @param raw_ Encoded bytes32 substrate.
    /// @return True if `raw_` encodes a `COLLATERAL_TOKEN` substrate.
    function isCollateralTokenSubstrate(bytes32 raw_) internal pure returns (bool) {
        return uint8(uint256(raw_) >> _FLAG_SHIFT) == uint8(TermFinanceSubstrateType.COLLATERAL_TOKEN);
    }
}
