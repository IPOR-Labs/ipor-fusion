// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";

/// @title AaveV4SubstrateType
/// @notice Type flag stored in the most significant byte (bits 255..248) of an Aave V4 substrate
/// @dev Flag 0 (Undefined) keeps an uninitialized bytes32 invalid
enum AaveV4SubstrateType {
    /// @dev 0 - Invalid/undefined (default Solidity zero value)
    Undefined,
    /// @dev 1 - Aave V4 reserve: (spoke, reserveId) + capability flags
    Reserve
}

/// @title AaveV4Substrate
/// @notice One granted Aave V4 reserve and what the Plasma Vault may do with it
/// @dev Aave V4 identifies a market by (Spoke, reserveId). The same underlying can be listed more than once
///      on a single Spoke (e.g. USDC via the Prime hub and USDC via the Core hub on the Bluechip Spoke),
///      so the reserve id - not the asset - is the unambiguous identifier. Reserve ids are append-only.
struct AaveV4Substrate {
    /// @notice Aave V4 Spoke contract address
    address spoke;
    /// @notice Reserve identifier within the Spoke
    uint32 reserveId;
    /// @notice True if the reserve may be enabled as collateral (AaveV4CollateralFuse.enter)
    bool isCollateral;
    /// @notice True if the reserve may be borrowed (AaveV4BorrowFuse.enter)
    bool canBorrow;
}

/// @title AaveV4ReserveGrant
/// @notice Effective permissions of the vault for a (spoke, reserveId) pair
/// @dev Union of all granted flag variants of the pair (see AaveV4SubstrateLib.getReserveGrant)
struct AaveV4ReserveGrant {
    /// @notice True if any substrate for the pair is granted
    bool granted;
    /// @notice True if a granted substrate for the pair has isCollateral
    bool isCollateral;
    /// @notice True if a granted substrate for the pair has canBorrow
    bool canBorrow;
}

/// @title AaveV4SubstrateLib
/// @author IPOR Labs
/// @notice Encoding, decoding and permission checks of typed substrates for the Aave V4 integration
/// @dev Substrate layout (bytes32):
///      +-----------+-----------------------+---------------+-------------------+------------------------+
///      | Bits      | 255..248 (8 bits)     | 247..88 (160) | 87..56 (32 bits)  | 55..48 (8 bits)        |
///      +-----------+-----------------------+---------------+-------------------+------------------------+
///      | Content   | type flag (1=Reserve) | spoke address | reserveId         | flags                  |
///      +-----------+-----------------------+---------------+-------------------+------------------------+
///      flags: bit0 = isCollateral, bit1 = canBorrow. Bits 47..0 are reserved and must be zero.
///
///      Permission semantics (Euler/Dolomite style):
///      - any granted substrate for (spoke, reserveId) allows supply, withdraw, repay and disabling collateral,
///      - isCollateral additionally allows enabling the reserve as collateral,
///      - canBorrow additionally allows borrowing the reserve,
///      - instant withdraw is allowed only for reserves that can never be collateral (health factor untouched).
///
///      Lookups are O(1): the four flag variants of a pair are probed with isMarketSubstrateGranted and
///      their union is returned, so the result does not depend on the order of granted substrates.
///      Atomists are expected to grant exactly one variant per reserve.
library AaveV4SubstrateLib {
    uint256 private constant _TYPE_SHIFT = 248;
    uint256 private constant _SPOKE_SHIFT = 88;
    uint256 private constant _RESERVE_ID_SHIFT = 56;
    uint256 private constant _FLAGS_SHIFT = 48;
    uint8 private constant _FLAG_IS_COLLATERAL = 0x01;
    uint8 private constant _FLAG_CAN_BORROW = 0x02;
    /// @dev All flag bits currently defined; any other flag bit makes the word non-canonical
    uint8 private constant _KNOWN_FLAGS_MASK = _FLAG_IS_COLLATERAL | _FLAG_CAN_BORROW;
    /// @dev Bits 47..0 are reserved and must be zero in a canonical word
    uint256 private constant _RESERVED_BITS_MASK = (uint256(1) << _FLAGS_SHIFT) - 1;

    /// @notice Thrown when a reserve id does not fit into the 32-bit substrate field
    /// @param reserveId The reserve id that overflowed
    error AaveV4SubstrateLibReserveIdOverflow(uint256 reserveId);

    /// @notice Encodes an AaveV4Substrate into a bytes32 word
    /// @param substrate_ The substrate to encode
    /// @return The encoded bytes32 substrate with the Reserve type flag
    function encode(AaveV4Substrate memory substrate_) internal pure returns (bytes32) {
        uint256 flags = (substrate_.isCollateral ? _FLAG_IS_COLLATERAL : 0) |
            (substrate_.canBorrow ? _FLAG_CAN_BORROW : 0);

        return
            bytes32(
                (uint256(AaveV4SubstrateType.Reserve) << _TYPE_SHIFT) |
                    (uint256(uint160(substrate_.spoke)) << _SPOKE_SHIFT) |
                    (uint256(substrate_.reserveId) << _RESERVE_ID_SHIFT) |
                    (flags << _FLAGS_SHIFT)
            );
    }

    /// @notice Convenience encoder taking loose parameters
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke (must fit uint32)
    /// @param isCollateral_ True if the reserve may be enabled as collateral
    /// @param canBorrow_ True if the reserve may be borrowed
    /// @return The encoded bytes32 substrate
    /// @custom:revert AaveV4SubstrateLibReserveIdOverflow When reserveId_ exceeds type(uint32).max
    function encodeReserve(
        address spoke_,
        uint256 reserveId_,
        bool isCollateral_,
        bool canBorrow_
    ) internal pure returns (bytes32) {
        if (reserveId_ > type(uint32).max) {
            revert AaveV4SubstrateLibReserveIdOverflow(reserveId_);
        }
        return encode(AaveV4Substrate(spoke_, uint32(reserveId_), isCollateral_, canBorrow_));
    }

    /// @notice Decodes a bytes32 word into an AaveV4Substrate (type flag is not validated)
    /// @param substrate_ The encoded bytes32 substrate
    /// @return substrate The decoded substrate
    function decode(bytes32 substrate_) internal pure returns (AaveV4Substrate memory substrate) {
        uint256 word = uint256(substrate_);
        substrate.spoke = address(uint160(word >> _SPOKE_SHIFT));
        substrate.reserveId = uint32(word >> _RESERVE_ID_SHIFT);
        uint8 flags = uint8(word >> _FLAGS_SHIFT);
        substrate.isCollateral = flags & _FLAG_IS_COLLATERAL != 0;
        substrate.canBorrow = flags & _FLAG_CAN_BORROW != 0;
    }

    /// @notice Decodes the type flag from a substrate
    /// @param substrate_ The encoded bytes32 substrate
    /// @return The substrate type (Undefined or Reserve)
    function decodeSubstrateType(bytes32 substrate_) internal pure returns (AaveV4SubstrateType) {
        uint8 flag = uint8(uint256(substrate_) >> _TYPE_SHIFT);
        if (flag > uint8(type(AaveV4SubstrateType).max)) {
            return AaveV4SubstrateType.Undefined;
        }
        return AaveV4SubstrateType(flag);
    }

    /// @notice Checks if a substrate is a canonical Reserve substrate
    /// @dev Strict predicate: the type flag must be Reserve, the reserved bits 47..0 must be zero and only the
    ///      known flag bits may be set. Non-canonical words are ignored by the balance fuse for the same reason
    ///      they never match a permission lookup (getReserveGrant probes canonical encodings only).
    /// @param substrate_ The encoded bytes32 substrate
    /// @return True if the substrate is a canonical Reserve substrate
    function isReserveSubstrate(bytes32 substrate_) internal pure returns (bool) {
        if (decodeSubstrateType(substrate_) != AaveV4SubstrateType.Reserve) {
            return false;
        }

        uint256 word = uint256(substrate_);

        if (word & _RESERVED_BITS_MASK != 0) {
            return false;
        }

        return (uint8(word >> _FLAGS_SHIFT) & ~_KNOWN_FLAGS_MASK) == 0;
    }

    /// @notice Returns the effective permissions for a (spoke, reserveId) pair in a market
    /// @dev Probes the four flag variants of the pair and returns their union (4 SLOADs, no iteration)
    /// @param marketId_ The market identifier
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke
    /// @return grant The effective permissions; all false when nothing is granted or reserveId_ exceeds uint32
    function getReserveGrant(
        uint256 marketId_,
        address spoke_,
        uint256 reserveId_
    ) internal view returns (AaveV4ReserveGrant memory grant) {
        if (reserveId_ > type(uint32).max) {
            return grant;
        }

        uint32 reserveId = uint32(reserveId_);

        bool plain = PlasmaVaultConfigLib.isMarketSubstrateGranted(
            marketId_,
            encode(AaveV4Substrate(spoke_, reserveId, false, false))
        );
        bool collateral = PlasmaVaultConfigLib.isMarketSubstrateGranted(
            marketId_,
            encode(AaveV4Substrate(spoke_, reserveId, true, false))
        );
        bool borrow = PlasmaVaultConfigLib.isMarketSubstrateGranted(
            marketId_,
            encode(AaveV4Substrate(spoke_, reserveId, false, true))
        );
        bool both = PlasmaVaultConfigLib.isMarketSubstrateGranted(
            marketId_,
            encode(AaveV4Substrate(spoke_, reserveId, true, true))
        );

        grant.granted = plain || collateral || borrow || both;
        grant.isCollateral = collateral || both;
        grant.canBorrow = borrow || both;
    }

    /// @notice Checks if the vault may supply to / withdraw from / repay the reserve
    /// @param marketId_ The market identifier
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke
    /// @return True if any substrate for the pair is granted
    function canSupply(uint256 marketId_, address spoke_, uint256 reserveId_) internal view returns (bool) {
        return getReserveGrant(marketId_, spoke_, reserveId_).granted;
    }

    /// @notice Checks if the vault may enable the reserve as collateral
    /// @param marketId_ The market identifier
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke
    /// @return True if a granted substrate for the pair has isCollateral
    function canCollateral(uint256 marketId_, address spoke_, uint256 reserveId_) internal view returns (bool) {
        return getReserveGrant(marketId_, spoke_, reserveId_).isCollateral;
    }

    /// @notice Checks if the vault may borrow the reserve
    /// @param marketId_ The market identifier
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke
    /// @return True if a granted substrate for the pair has canBorrow
    function canBorrow(uint256 marketId_, address spoke_, uint256 reserveId_) internal view returns (bool) {
        return getReserveGrant(marketId_, spoke_, reserveId_).canBorrow;
    }

    /// @notice Checks if the reserve may be used for instant withdrawals
    /// @dev Only reserves that can never be enabled as collateral are eligible, so user withdrawals can
    ///      never degrade the health factor of a leveraged position
    /// @param marketId_ The market identifier
    /// @param spoke_ Aave V4 Spoke contract address
    /// @param reserveId_ Reserve identifier within the Spoke
    /// @return True if the pair is granted and no granted variant has isCollateral
    function canInstantWithdraw(uint256 marketId_, address spoke_, uint256 reserveId_) internal view returns (bool) {
        AaveV4ReserveGrant memory grant = getReserveGrant(marketId_, spoke_, reserveId_);
        return grant.granted && !grant.isCollateral;
    }
}
