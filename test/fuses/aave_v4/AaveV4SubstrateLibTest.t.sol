// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {
    AaveV4SubstrateLib,
    AaveV4Substrate,
    AaveV4SubstrateType,
    AaveV4ReserveGrant
} from "../../../contracts/fuses/aave_v4/AaveV4SubstrateLib.sol";

/// @title AaveV4SubstrateLibTest
/// @notice Tests for AaveV4SubstrateLib encoding, decoding and grant semantics
/// @dev Grant tests use the test contract's own storage via PlasmaVaultConfigLib (same as a delegatecalled fuse)
contract AaveV4SubstrateLibTest is Test {
    uint256 public constant MARKET_ID = 49;

    address public constant SPOKE = 0x973a023A77420ba610f06b3858aD991Df6d85A08;
    address public constant OTHER_SPOKE = 0x94e7A5dCbE816e498b89aB752661904E2F56c485;
    uint32 public constant RESERVE_ID = 7;

    // ============ Encoding layout ============

    function testShouldEncodeReserveWithExpectedLayout() public pure {
        // given
        AaveV4Substrate memory substrate = AaveV4Substrate({
            spoke: SPOKE,
            reserveId: RESERVE_ID,
            isCollateral: true,
            canBorrow: true
        });

        // when
        bytes32 encoded = AaveV4SubstrateLib.encode(substrate);

        // then - [type=1 | spoke | reserveId | flags=0x03]
        uint256 expected = (uint256(1) << 248) |
            (uint256(uint160(SPOKE)) << 88) |
            (uint256(RESERVE_ID) << 56) |
            (uint256(0x03) << 48);
        assertEq(encoded, bytes32(expected), "Layout mismatch");
        assertEq(uint8(uint256(encoded) >> 248), 1, "Type byte should be 1 (Reserve)");
        assertEq(uint256(encoded) & ((1 << 48) - 1), 0, "Reserved low bits must be zero");
    }

    function testShouldEncodeIsCollateralFlagOnly() public pure {
        bytes32 encoded = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false);
        assertEq(uint8(uint256(encoded) >> 48), 0x01, "flags should be 0x01");
    }

    function testShouldEncodeCanBorrowFlagOnly() public pure {
        bytes32 encoded = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, true);
        assertEq(uint8(uint256(encoded) >> 48), 0x02, "flags should be 0x02");
    }

    function testShouldEncodeReserveMatchStructEncoding() public pure {
        bytes32 viaStruct = AaveV4SubstrateLib.encode(
            AaveV4Substrate({spoke: SPOKE, reserveId: RESERVE_ID, isCollateral: false, canBorrow: true})
        );
        bytes32 viaParams = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, true);
        assertEq(viaStruct, viaParams);
    }

    function testShouldRevertEncodeReserveWhenReserveIdOverflows() public {
        uint256 overflowing = uint256(type(uint32).max) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(AaveV4SubstrateLib.AaveV4SubstrateLibReserveIdOverflow.selector, overflowing)
        );
        this.encodeReserveExternal(SPOKE, overflowing, false, false);
    }

    /// @dev External wrapper so that vm.expectRevert catches the library revert
    function encodeReserveExternal(
        address spoke_,
        uint256 reserveId_,
        bool isCollateral_,
        bool canBorrow_
    ) external pure returns (bytes32) {
        return AaveV4SubstrateLib.encodeReserve(spoke_, reserveId_, isCollateral_, canBorrow_);
    }

    function testShouldProduceDifferentWordsForDifferentFlags() public pure {
        bytes32 plain = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, false);
        bytes32 collateral = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false);
        bytes32 borrow = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, true);
        bytes32 both = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true);

        assertTrue(plain != collateral && plain != borrow && plain != both);
        assertTrue(collateral != borrow && collateral != both && borrow != both);
    }

    function testShouldProduceDifferentWordsForDifferentReserveIds() public pure {
        bytes32 reserve4 = AaveV4SubstrateLib.encodeReserve(SPOKE, 4, false, true);
        bytes32 reserve7 = AaveV4SubstrateLib.encodeReserve(SPOKE, 7, false, true);
        assertTrue(reserve4 != reserve7, "Duplicate underlying on one spoke must be distinguishable by reserveId");
    }

    // ============ Decoding ============

    function testShouldDecodeEncodedSubstrate() public pure {
        bytes32 encoded = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false);

        AaveV4Substrate memory decoded = AaveV4SubstrateLib.decode(encoded);

        assertEq(decoded.spoke, SPOKE);
        assertEq(decoded.reserveId, RESERVE_ID);
        assertTrue(decoded.isCollateral);
        assertFalse(decoded.canBorrow);
    }

    function testFuzzEncodeDecodeRoundTrip(
        address spoke_,
        uint32 reserveId_,
        bool isCollateral_,
        bool canBorrow_
    ) public pure {
        AaveV4Substrate memory original = AaveV4Substrate({
            spoke: spoke_,
            reserveId: reserveId_,
            isCollateral: isCollateral_,
            canBorrow: canBorrow_
        });

        AaveV4Substrate memory decoded = AaveV4SubstrateLib.decode(AaveV4SubstrateLib.encode(original));

        assertEq(decoded.spoke, original.spoke);
        assertEq(decoded.reserveId, original.reserveId);
        assertEq(decoded.isCollateral, original.isCollateral);
        assertEq(decoded.canBorrow, original.canBorrow);
    }

    function testShouldHandleMaxAddressAndMaxReserveId() public pure {
        address maxAddress = address(type(uint160).max);
        bytes32 encoded = AaveV4SubstrateLib.encodeReserve(maxAddress, type(uint32).max, true, true);

        AaveV4Substrate memory decoded = AaveV4SubstrateLib.decode(encoded);

        assertEq(decoded.spoke, maxAddress);
        assertEq(decoded.reserveId, type(uint32).max);
        assertTrue(decoded.isCollateral);
        assertTrue(decoded.canBorrow);
        assertTrue(AaveV4SubstrateLib.isReserveSubstrate(encoded));
    }

    // ============ Type flag ============

    function testShouldReturnReserveTypeForEncodedSubstrate() public pure {
        bytes32 encoded = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, false);
        assertTrue(AaveV4SubstrateLib.decodeSubstrateType(encoded) == AaveV4SubstrateType.Reserve);
        assertTrue(AaveV4SubstrateLib.isReserveSubstrate(encoded));
    }

    function testShouldReturnUndefinedForZeroWord() public pure {
        assertTrue(AaveV4SubstrateLib.decodeSubstrateType(bytes32(0)) == AaveV4SubstrateType.Undefined);
        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(bytes32(0)));
    }

    function testShouldReturnUndefinedForUnknownTypeFlag() public pure {
        bytes32 flag2 = bytes32(uint256(2) << 248);
        bytes32 flagMax = bytes32(uint256(0xFF) << 248);
        assertTrue(AaveV4SubstrateLib.decodeSubstrateType(flag2) == AaveV4SubstrateType.Undefined);
        assertTrue(AaveV4SubstrateLib.decodeSubstrateType(flagMax) == AaveV4SubstrateType.Undefined);
        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(flag2));
    }

    function testShouldRejectWordWithReservedBitsSet() public pure {
        bytes32 canonical = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false);
        bytes32 dirty = bytes32(uint256(canonical) | 1); // bit 0 of the reserved area

        assertTrue(AaveV4SubstrateLib.isReserveSubstrate(canonical));
        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(dirty), "reserved bits must be zero");
        // decode itself is lenient; the strict predicate is what consumers must use
        assertEq(AaveV4SubstrateLib.decode(dirty).spoke, SPOKE);
    }

    function testShouldRejectWordWithUnknownFlagBits() public pure {
        bytes32 canonical = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true);
        bytes32 unknownFlag = bytes32(uint256(canonical) | (uint256(0x04) << 48));

        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(unknownFlag), "unknown flag bit must be rejected");
    }

    function testShouldNotGrantNonCanonicalWord() public {
        // a word with dirty reserved bits is neither a reserve substrate nor a grant for the pair
        bytes32 dirty = bytes32(uint256(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true)) | 1);
        _grant(_single(dirty));

        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(dirty));
        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
    }

    function testShouldNotTreatPlainAddressWordAsReserve() public pure {
        // a legacy "asset as address" substrate has type byte 0
        bytes32 addressWord = PlasmaVaultConfigLib.addressToBytes32(SPOKE);
        assertFalse(AaveV4SubstrateLib.isReserveSubstrate(addressWord));
    }

    // ============ Grant semantics ============

    function testShouldReturnNotGrantedWhenNothingGranted() public view {
        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(MARKET_ID, SPOKE, RESERVE_ID);

        assertFalse(grant.granted);
        assertFalse(grant.isCollateral);
        assertFalse(grant.canBorrow);
        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canCollateral(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID));
    }

    function testShouldReturnPlainGrant() public {
        // given
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, false)));

        // then
        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(MARKET_ID, SPOKE, RESERVE_ID);
        assertTrue(grant.granted);
        assertFalse(grant.isCollateral);
        assertFalse(grant.canBorrow);

        assertTrue(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canCollateral(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));
        assertTrue(AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID));
    }

    function testShouldReturnCollateralGrant() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false)));

        assertTrue(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
        assertTrue(AaveV4SubstrateLib.canCollateral(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(
            AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID),
            "collateral reserve is never instant-withdrawable"
        );
    }

    function testShouldReturnBorrowGrant() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, true)));

        assertTrue(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canCollateral(MARKET_ID, SPOKE, RESERVE_ID));
        assertTrue(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));
        assertTrue(
            AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID),
            "borrowable but non-collateral reserve is instant-withdrawable"
        );
    }

    function testShouldReturnBothFlagsGrant() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true)));

        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(MARKET_ID, SPOKE, RESERVE_ID);
        assertTrue(grant.granted && grant.isCollateral && grant.canBorrow);
        assertFalse(AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID));
    }

    function testShouldReturnUnionOfGrantedVariants() public {
        // given - two variants of the same pair
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, false);
        substrates[1] = AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, true);
        _grant(substrates);

        // then
        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(MARKET_ID, SPOKE, RESERVE_ID);
        assertTrue(grant.granted);
        assertTrue(grant.isCollateral, "union: collateral from variant 0");
        assertTrue(grant.canBorrow, "union: borrow from variant 1");
        assertFalse(AaveV4SubstrateLib.canInstantWithdraw(MARKET_ID, SPOKE, RESERVE_ID));
    }

    function testShouldNotGrantOtherReserveIdOnSameSpoke() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, 4, true, true)));

        assertTrue(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, 4));
        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, 7), "reserve 7 must not inherit grant of reserve 4");
    }

    function testShouldNotGrantSameReserveIdOnOtherSpoke() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true)));

        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID, OTHER_SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canBorrow(MARKET_ID, OTHER_SPOKE, RESERVE_ID));
    }

    function testShouldNotGrantOtherMarket() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true)));

        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID + 1, SPOKE, RESERVE_ID));
    }

    function testShouldReturnNotGrantedWhenReserveIdExceedsUint32() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, 0, true, true)));

        // reserveId 2^32 must not alias reserve 0 (uint32 truncation)
        AaveV4ReserveGrant memory grant = AaveV4SubstrateLib.getReserveGrant(
            MARKET_ID,
            SPOKE,
            uint256(type(uint32).max) + 1
        );
        assertFalse(grant.granted);
        assertFalse(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, uint256(type(uint32).max) + 1));
    }

    function testShouldRevokeGrantWhenRegrantedWithoutReserve() public {
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, true, true)));
        assertTrue(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));

        // when - regrant with a plain variant only (grantMarketSubstrates replaces the set)
        _grant(_single(AaveV4SubstrateLib.encodeReserve(SPOKE, RESERVE_ID, false, false)));

        // then
        assertTrue(AaveV4SubstrateLib.canSupply(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canCollateral(MARKET_ID, SPOKE, RESERVE_ID));
        assertFalse(AaveV4SubstrateLib.canBorrow(MARKET_ID, SPOKE, RESERVE_ID));
    }

    // ============ Helpers ============

    function _grant(bytes32[] memory substrates_) private {
        PlasmaVaultConfigLib.grantMarketSubstrates(MARKET_ID, substrates_);
    }

    function _single(bytes32 substrate_) private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](1);
        substrates[0] = substrate_;
    }
}
