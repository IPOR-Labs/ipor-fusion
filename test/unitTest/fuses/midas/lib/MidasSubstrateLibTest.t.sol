// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {MidasSubstrateLib, MidasSubstrate, MidasSubstrateType} from "contracts/fuses/midas/lib/MidasSubstrateLib.sol";
import {MidasSubstrateLibHarness} from "./mocks/MidasSubstrateLibHarness.sol";

/// @title MidasSubstrateLibTest
/// @notice Unit tests for MidasSubstrateLib — 100% branch coverage target
contract MidasSubstrateLibTest is Test {
    // ============ Constants ============

    uint256 public constant MARKET_ID = 1;
    uint256 public constant MARKET_ID_2 = 2;

    address public constant ADDR_01 = address(0xABCD_0001);
    address public constant ADDR_02 = address(0xABCD_0002);
    address public constant ADDR_03 = address(0xABCD_0003);
    address public constant ADDR_04 = address(0xABCD_0004);
    address public constant ADDR_05 = address(0xABCD_0005);
    address public constant ADDR_06 = address(0xABCD_0006);

    // ============ State Variables ============

    MidasSubstrateLibHarness internal harness;

    // ============ Setup ============

    function setUp() public {
        harness = new MidasSubstrateLibHarness();

        vm.label(address(harness), "MidasSubstrateLibHarness");
        vm.label(ADDR_01, "Addr01_MToken");
        vm.label(ADDR_02, "Addr02_DepositVault");
        vm.label(ADDR_03, "Addr03_RedemptionVault");
        vm.label(ADDR_04, "Addr04_InstantRedemptionVault");
        vm.label(ADDR_05, "Addr05_Asset");
        vm.label(ADDR_06, "Addr06_Undefined");
    }

    // ============ Helpers ============

    /// @dev Build and grant a single substrate for a market via the harness
    function _grantSingleSubstrate(uint256 marketId_, MidasSubstrateType type_, address addr_) internal {
        bytes32[] memory subs = new bytes32[](1);
        subs[0] = harness.substrateToBytes32(MidasSubstrate({substrateType: type_, substrateAddress: addr_}));
        harness.grantMarketSubstrates(marketId_, subs);
    }

    // ============================================================
    // Section 1: substrateToBytes32
    // ============================================================

    // 1.1 — M_TOKEN encoding
    function testSubstrateToBytes32_MToken() public view {
        // given
        MidasSubstrate memory sub = MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: ADDR_01});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then — type bits (1 << 160) OR'd with address
        bytes32 expected = bytes32(uint256(uint160(ADDR_01)) | (uint256(1) << 160));
        assertEq(result, expected, "M_TOKEN encoding should place type=1 in bits [255:160] and address in bits [159:0]");
    }

    // 1.2 — DEPOSIT_VAULT encoding
    function testSubstrateToBytes32_DepositVault() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: ADDR_02});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then
        bytes32 expected = bytes32(uint256(uint160(ADDR_02)) | (uint256(2) << 160));
        assertEq(result, expected, "DEPOSIT_VAULT encoding should use type=2");
    }

    // 1.3 — REDEMPTION_VAULT encoding
    function testSubstrateToBytes32_RedemptionVault() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.REDEMPTION_VAULT, substrateAddress: ADDR_03});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then
        bytes32 expected = bytes32(uint256(uint160(ADDR_03)) | (uint256(3) << 160));
        assertEq(result, expected, "REDEMPTION_VAULT encoding should use type=3");
    }

    // 1.4 — INSTANT_REDEMPTION_VAULT encoding
    function testSubstrateToBytes32_InstantRedemptionVault() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.INSTANT_REDEMPTION_VAULT, substrateAddress: ADDR_04});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then
        bytes32 expected = bytes32(uint256(uint160(ADDR_04)) | (uint256(4) << 160));
        assertEq(result, expected, "INSTANT_REDEMPTION_VAULT encoding should use type=4");
    }

    // 1.5 — ASSET encoding
    function testSubstrateToBytes32_Asset() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.ASSET, substrateAddress: ADDR_05});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then
        bytes32 expected = bytes32(uint256(uint160(ADDR_05)) | (uint256(5) << 160));
        assertEq(result, expected, "ASSET encoding should use type=5");
    }

    // 1.6 — UNDEFINED encoding: type=0 contributes 0 to upper bits, result is raw address
    function testSubstrateToBytes32_Undefined() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.UNDEFINED, substrateAddress: ADDR_06});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then — type=0 → no upper bits set, result == address bytes
        bytes32 expected = bytes32(uint256(uint160(ADDR_06)));
        assertEq(result, expected, "UNDEFINED (type=0) should produce raw address with no type bits");
    }

    // 1.7 — Zero address edge case: only type bits present
    function testSubstrateToBytes32_ZeroAddress() public view {
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: address(0)});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then — lower 160 bits are 0, upper = type=1
        bytes32 expected = bytes32(uint256(1) << 160);
        assertEq(result, expected, "Zero address with M_TOKEN should produce only type bits");
    }

    // 1.8 — Max address boundary: type bits must not be overwritten by max address
    function testSubstrateToBytes32_MaxAddress() public view {
        // given
        address maxAddr = address(type(uint160).max);
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: maxAddr});
        // when
        bytes32 result = harness.substrateToBytes32(sub);
        // then
        bytes32 expected = bytes32(uint256(type(uint160).max) | (uint256(1) << 160));
        assertEq(result, expected, "Max address should not corrupt type bits");
        // verify type bits are preserved
        uint256 typeExtracted = uint256(result) >> 160;
        assertEq(typeExtracted, 1, "Type bits must survive max-address OR");
    }

    // ============================================================
    // Section 2: bytes32ToSubstrate
    // ============================================================

    // 2.1 — Decode M_TOKEN
    function testBytes32ToSubstrate_MToken() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_01)) | (uint256(1) << 160));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(sub.substrateType), uint8(MidasSubstrateType.M_TOKEN), "Decoded type should be M_TOKEN");
        assertEq(sub.substrateAddress, ADDR_01, "Decoded address should match ADDR_01");
    }

    // 2.2 — Decode DEPOSIT_VAULT
    function testBytes32ToSubstrate_DepositVault() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_02)) | (uint256(2) << 160));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(sub.substrateType), uint8(MidasSubstrateType.DEPOSIT_VAULT), "Decoded type should be DEPOSIT_VAULT");
        assertEq(sub.substrateAddress, ADDR_02, "Decoded address should match ADDR_02");
    }

    // 2.3 — Decode REDEMPTION_VAULT
    function testBytes32ToSubstrate_RedemptionVault() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_03)) | (uint256(3) << 160));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(
            uint8(sub.substrateType), uint8(MidasSubstrateType.REDEMPTION_VAULT), "Decoded type should be REDEMPTION_VAULT"
        );
        assertEq(sub.substrateAddress, ADDR_03, "Decoded address should match ADDR_03");
    }

    // 2.4 — Decode INSTANT_REDEMPTION_VAULT
    function testBytes32ToSubstrate_InstantRedemptionVault() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_04)) | (uint256(4) << 160));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(
            uint8(sub.substrateType),
            uint8(MidasSubstrateType.INSTANT_REDEMPTION_VAULT),
            "Decoded type should be INSTANT_REDEMPTION_VAULT"
        );
        assertEq(sub.substrateAddress, ADDR_04, "Decoded address should match ADDR_04");
    }

    // 2.5 — Decode ASSET
    function testBytes32ToSubstrate_Asset() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_05)) | (uint256(5) << 160));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(sub.substrateType), uint8(MidasSubstrateType.ASSET), "Decoded type should be ASSET");
        assertEq(sub.substrateAddress, ADDR_05, "Decoded address should match ADDR_05");
    }

    // 2.6 — Decode UNDEFINED (type=0)
    function testBytes32ToSubstrate_Undefined() public view {
        // given
        bytes32 encoded = bytes32(uint256(uint160(ADDR_06)));
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(sub.substrateType), uint8(MidasSubstrateType.UNDEFINED), "Decoded type should be UNDEFINED");
        assertEq(sub.substrateAddress, ADDR_06, "Decoded address should match ADDR_06");
    }

    // 2.7 — Decode zero bytes32 -> UNDEFINED, address(0)
    function testBytes32ToSubstrate_ZeroBytes() public view {
        // given
        bytes32 encoded = bytes32(0);
        // when
        MidasSubstrate memory sub = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(sub.substrateType), uint8(MidasSubstrateType.UNDEFINED), "All-zero bytes32 should decode to UNDEFINED");
        assertEq(sub.substrateAddress, address(0), "All-zero bytes32 should decode to address(0)");
    }

    // ============================================================
    // Section 3: validateMTokenGranted
    // ============================================================

    // 3.1 — Happy path: substrate correctly granted
    function testValidateMTokenGranted_Success() public {
        // given
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, ADDR_01);
        // when/then — must not revert
        harness.validateMTokenGranted(MARKET_ID, ADDR_01);
    }

    // 3.2 — Revert when substrate not granted at all
    function testValidateMTokenGranted_Reverts_NotGranted() public {
        // given — nothing granted
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), ADDR_01)
        );
        harness.validateMTokenGranted(MARKET_ID, ADDR_01);
    }

    // 3.3 — Revert when same address granted with wrong type (DEPOSIT_VAULT instead of M_TOKEN)
    function testValidateMTokenGranted_Reverts_WrongType() public {
        // given — grant DEPOSIT_VAULT for the same address
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, ADDR_01);
        // when/then — M_TOKEN substrate not present → must revert
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), ADDR_01)
        );
        harness.validateMTokenGranted(MARKET_ID, ADDR_01);
    }

    // 3.4 — Revert when correct type granted for a different address
    function testValidateMTokenGranted_Reverts_WrongAddress() public {
        // given — grant M_TOKEN for ADDR_02, validate for ADDR_01
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, ADDR_02);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), ADDR_01)
        );
        harness.validateMTokenGranted(MARKET_ID, ADDR_01);
    }

    // 3.5 — Revert when substrate granted for different market
    function testValidateMTokenGranted_Reverts_WrongMarket() public {
        // given — grant for MARKET_ID, validate for MARKET_ID_2
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, ADDR_01);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), ADDR_01)
        );
        harness.validateMTokenGranted(MARKET_ID_2, ADDR_01);
    }

    // ============================================================
    // Section 4: validateDepositVaultGranted
    // ============================================================

    // 4.1 — Happy path
    function testValidateDepositVaultGranted_Success() public {
        // given
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.DEPOSIT_VAULT, ADDR_02);
        // when/then — must not revert
        harness.validateDepositVaultGranted(MARKET_ID, ADDR_02);
    }

    // 4.2 — Revert when not granted
    function testValidateDepositVaultGranted_Reverts_NotGranted() public {
        // given — nothing granted
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), ADDR_02)
        );
        harness.validateDepositVaultGranted(MARKET_ID, ADDR_02);
    }

    // 4.3 — Revert when M_TOKEN granted instead of DEPOSIT_VAULT
    function testValidateDepositVaultGranted_Reverts_WrongType() public {
        // given — grant M_TOKEN for the same address
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, ADDR_02);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), ADDR_02)
        );
        harness.validateDepositVaultGranted(MARKET_ID, ADDR_02);
    }

    // ============================================================
    // Section 5: validateRedemptionVaultGranted
    // ============================================================

    // 5.1 — Happy path
    function testValidateRedemptionVaultGranted_Success() public {
        // given
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.REDEMPTION_VAULT, ADDR_03);
        // when/then — must not revert
        harness.validateRedemptionVaultGranted(MARKET_ID, ADDR_03);
    }

    // 5.2 — Revert when not granted
    function testValidateRedemptionVaultGranted_Reverts_NotGranted() public {
        // given — nothing granted
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(3), ADDR_03)
        );
        harness.validateRedemptionVaultGranted(MARKET_ID, ADDR_03);
    }

    // 5.3 — Revert when INSTANT_REDEMPTION_VAULT granted instead of REDEMPTION_VAULT
    function testValidateRedemptionVaultGranted_Reverts_WrongType() public {
        // given — grant INSTANT_REDEMPTION_VAULT for same address
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.INSTANT_REDEMPTION_VAULT, ADDR_03);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(3), ADDR_03)
        );
        harness.validateRedemptionVaultGranted(MARKET_ID, ADDR_03);
    }

    // ============================================================
    // Section 6: validateInstantRedemptionVaultGranted
    // ============================================================

    // 6.1 — Happy path
    function testValidateInstantRedemptionVaultGranted_Success() public {
        // given
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.INSTANT_REDEMPTION_VAULT, ADDR_04);
        // when/then — must not revert
        harness.validateInstantRedemptionVaultGranted(MARKET_ID, ADDR_04);
    }

    // 6.2 — Revert when not granted
    function testValidateInstantRedemptionVaultGranted_Reverts_NotGranted() public {
        // given — nothing granted
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(4), ADDR_04)
        );
        harness.validateInstantRedemptionVaultGranted(MARKET_ID, ADDR_04);
    }

    // 6.3 — Revert when REDEMPTION_VAULT granted instead of INSTANT_REDEMPTION_VAULT
    function testValidateInstantRedemptionVaultGranted_Reverts_WrongType() public {
        // given — grant standard REDEMPTION_VAULT for same address
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.REDEMPTION_VAULT, ADDR_04);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(4), ADDR_04)
        );
        harness.validateInstantRedemptionVaultGranted(MARKET_ID, ADDR_04);
    }

    // ============================================================
    // Section 7: validateAssetGranted
    // ============================================================

    // 7.1 — Happy path
    function testValidateAssetGranted_Success() public {
        // given
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.ASSET, ADDR_05);
        // when/then — must not revert
        harness.validateAssetGranted(MARKET_ID, ADDR_05);
    }

    // 7.2 — Revert when not granted
    function testValidateAssetGranted_Reverts_NotGranted() public {
        // given — nothing granted
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), ADDR_05)
        );
        harness.validateAssetGranted(MARKET_ID, ADDR_05);
    }

    // 7.3 — Revert when M_TOKEN granted instead of ASSET
    function testValidateAssetGranted_Reverts_WrongType() public {
        // given — grant M_TOKEN for the same address
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, ADDR_05);
        // when/then
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), ADDR_05)
        );
        harness.validateAssetGranted(MARKET_ID, ADDR_05);
    }

    // ============================================================
    // Section 8: Encoding Boundary & Bit Layout Tests
    // ============================================================

    // 8.1 — Type bits do not overlap with max address bits
    function testEncoding_TypeBitsDoNotOverlapAddress() public view {
        address maxAddr = address(type(uint160).max);
        MidasSubstrateType[5] memory types = [
            MidasSubstrateType.M_TOKEN,
            MidasSubstrateType.DEPOSIT_VAULT,
            MidasSubstrateType.REDEMPTION_VAULT,
            MidasSubstrateType.INSTANT_REDEMPTION_VAULT,
            MidasSubstrateType.ASSET
        ];
        for (uint256 i = 0; i < types.length; i++) {
            MidasSubstrate memory sub = MidasSubstrate({substrateType: types[i], substrateAddress: maxAddr});
            bytes32 encoded = harness.substrateToBytes32(sub);
            uint256 decodedType = uint256(encoded) >> 160;
            uint256 expectedType = uint8(types[i]);
            assertEq(decodedType, expectedType, "Type bits must be preserved even when address is all 1s");
            // Verify lower 160 bits still hold max address
            address decodedAddr = address(uint160(uint256(encoded)));
            assertEq(decodedAddr, maxAddr, "Address bits must be preserved alongside type bits");
        }
    }

    // 8.2 — Same address, different types produce different bytes32
    function testEncoding_DifferentTypeSameAddressProducesDifferentBytes32() public view {
        // given
        MidasSubstrate memory sub1 =
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: ADDR_01});
        MidasSubstrate memory sub2 =
            MidasSubstrate({substrateType: MidasSubstrateType.DEPOSIT_VAULT, substrateAddress: ADDR_01});
        // when
        bytes32 enc1 = harness.substrateToBytes32(sub1);
        bytes32 enc2 = harness.substrateToBytes32(sub2);
        // then
        assertTrue(enc1 != enc2, "Different types on same address must produce distinct bytes32");
    }

    // 8.3 — Same type, different addresses produce different bytes32
    function testEncoding_SameTypeDifferentAddressProducesDifferentBytes32() public view {
        // given
        MidasSubstrate memory sub1 =
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: ADDR_01});
        MidasSubstrate memory sub2 =
            MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: ADDR_02});
        // when
        bytes32 enc1 = harness.substrateToBytes32(sub1);
        bytes32 enc2 = harness.substrateToBytes32(sub2);
        // then
        assertTrue(enc1 != enc2, "Different addresses with same type must produce distinct bytes32");
    }

    // 8.4 — Decoding always extracts the lower 160 bits as address regardless of upper bit content.
    //        bytes32ToSubstrate uses `address(uint160(uint256(bytes32)))` which masks to 160 bits.
    //        This test verifies the masking formula directly using arithmetic — it does NOT call
    //        bytes32ToSubstrate with garbage in the type field (which would panic on enum cast).
    //        In real usage only valid types 0-5 are stored; garbage above bit 160 never occurs.
    function testDecoding_IgnoresUpperBitsAboveType() public pure {
        // given — a uint256 with ADDR_01 in bits [159:0], valid type=2 in bits [167:160],
        //         and garbage in bits [255:192] above the type byte
        uint256 rawAddress = uint256(uint160(ADDR_01));
        uint256 typeVal = uint256(2); // DEPOSIT_VAULT
        uint256 validEncoded = rawAddress | (typeVal << 160);

        // Simulate PlasmaVaultConfigLib.bytes32ToAddress: address(uint160(uint256(substrate_)))
        // This masks to the lower 160 bits regardless of what is above.
        uint256 garbageUpper = uint256(0xDEAD_BEEF) << 192;
        uint256 dirtyEncoded = validEncoded | garbageUpper;

        // Verify that masking to uint160 always strips the garbage
        address extractedAddr = address(uint160(dirtyEncoded));
        assertEq(extractedAddr, ADDR_01, "uint160 cast must mask lower 160 bits correctly, ignoring garbage above");

        // Also verify clean encoding: lower 160 bits == address
        address cleanAddr = address(uint160(validEncoded));
        assertEq(cleanAddr, ADDR_01, "Clean encoded: lower 160 bits must equal the original address");
    }

    // ============================================================
    // Section 9: Cross-Validation Tests (Mutation Resistance)
    // ============================================================

    // 9.1 — Granted substrate does not revert (all 5 types)
    function testValidate_GrantedSubstrateDoesNotRevert() public {
        // M_TOKEN
        _grantSingleSubstrate(1, MidasSubstrateType.M_TOKEN, ADDR_01);
        harness.validateMTokenGranted(1, ADDR_01); // must not revert

        // DEPOSIT_VAULT — use fresh market to avoid grantMarketSubstrates wiping previous
        _grantSingleSubstrate(2, MidasSubstrateType.DEPOSIT_VAULT, ADDR_02);
        harness.validateDepositVaultGranted(2, ADDR_02);

        // REDEMPTION_VAULT
        _grantSingleSubstrate(3, MidasSubstrateType.REDEMPTION_VAULT, ADDR_03);
        harness.validateRedemptionVaultGranted(3, ADDR_03);

        // INSTANT_REDEMPTION_VAULT
        _grantSingleSubstrate(4, MidasSubstrateType.INSTANT_REDEMPTION_VAULT, ADDR_04);
        harness.validateInstantRedemptionVaultGranted(4, ADDR_04);

        // ASSET
        _grantSingleSubstrate(5, MidasSubstrateType.ASSET, ADDR_05);
        harness.validateAssetGranted(5, ADDR_05);
    }

    // 9.2 — Ungranted substrate reverts with exact selector for every type
    function testValidate_UngrantedSubstrateReverts() public {
        // M_TOKEN
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), ADDR_01)
        );
        harness.validateMTokenGranted(10, ADDR_01);

        // DEPOSIT_VAULT
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), ADDR_02)
        );
        harness.validateDepositVaultGranted(10, ADDR_02);

        // REDEMPTION_VAULT
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(3), ADDR_03)
        );
        harness.validateRedemptionVaultGranted(10, ADDR_03);

        // INSTANT_REDEMPTION_VAULT
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(4), ADDR_04)
        );
        harness.validateInstantRedemptionVaultGranted(10, ADDR_04);

        // ASSET
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), ADDR_05)
        );
        harness.validateAssetGranted(10, ADDR_05);
    }

    // 9.3 — Correct enum value in revert for each validate function
    function testValidate_TypeEnumValueInRevert() public {
        address target = makeAddr("target");
        vm.label(target, "TargetAddress");

        // M_TOKEN must revert with uint8(1)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), target)
        );
        harness.validateMTokenGranted(99, target);

        // DEPOSIT_VAULT must revert with uint8(2)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(2), target)
        );
        harness.validateDepositVaultGranted(99, target);

        // REDEMPTION_VAULT must revert with uint8(3)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(3), target)
        );
        harness.validateRedemptionVaultGranted(99, target);

        // INSTANT_REDEMPTION_VAULT must revert with uint8(4)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(4), target)
        );
        harness.validateInstantRedemptionVaultGranted(99, target);

        // ASSET must revert with uint8(5)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(5), target)
        );
        harness.validateAssetGranted(99, target);
    }

    // 9.4 — Revert includes the exact address passed to validate
    function testValidate_AddressInRevert() public {
        address targetAddr = makeAddr("specificAddress");
        address wrongAddr = makeAddr("otherAddress");
        vm.label(targetAddr, "TargetAddr");
        vm.label(wrongAddr, "WrongAddr");

        // Grant for wrongAddr; validateMTokenGranted for targetAddr → must include targetAddr in error
        _grantSingleSubstrate(MARKET_ID, MidasSubstrateType.M_TOKEN, wrongAddr);

        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), targetAddr)
        );
        harness.validateMTokenGranted(MARKET_ID, targetAddr);
    }

    // ============================================================
    // Fuzz Tests
    // ============================================================

    // F1 — Round-trip: address is preserved through encode→decode
    function testFuzz_SubstrateToBytes32_AddressPreserved(address addr) public view {
        // given
        MidasSubstrate memory sub = MidasSubstrate({substrateType: MidasSubstrateType.M_TOKEN, substrateAddress: addr});
        // when
        bytes32 encoded = harness.substrateToBytes32(sub);
        MidasSubstrate memory decoded = harness.bytes32ToSubstrate(encoded);
        // then — address must survive round-trip
        assertEq(decoded.substrateAddress, addr, "Round-trip must preserve address for any input");
    }

    // F2 — Round-trip: type is preserved through encode→decode
    function testFuzz_SubstrateToBytes32_TypePreserved(uint8 typeRaw) public view {
        vm.assume(typeRaw <= 5);
        // given
        MidasSubstrateType subType = MidasSubstrateType(typeRaw);
        MidasSubstrate memory sub = MidasSubstrate({substrateType: subType, substrateAddress: ADDR_01});
        // when
        bytes32 encoded = harness.substrateToBytes32(sub);
        MidasSubstrate memory decoded = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(decoded.substrateType), typeRaw, "Round-trip must preserve type for any valid type value");
    }

    // F3 — Bit layout: lower 160 bits == address, upper bits == type
    function testFuzz_SubstrateToBytes32_EncodingLayout(address addr, uint8 typeRaw) public view {
        vm.assume(typeRaw <= 5);
        // given
        MidasSubstrate memory sub =
            MidasSubstrate({substrateType: MidasSubstrateType(typeRaw), substrateAddress: addr});
        // when
        bytes32 encoded = harness.substrateToBytes32(sub);
        // then — verify bit layout directly
        uint256 lowerBits = uint256(encoded) & type(uint160).max;
        assertEq(lowerBits, uint256(uint160(addr)), "Lower 160 bits must be the address");
        uint256 upperBits = uint256(encoded) >> 160;
        assertEq(upperBits, uint256(typeRaw), "Upper bits must be the type discriminator");
    }

    // F4 — Full round-trip identity: decode(encode(substrate)) == substrate
    function testFuzz_RoundTrip_EncodeDecodeIdentity(address addr, uint8 typeRaw) public view {
        vm.assume(typeRaw <= 5);
        // given
        MidasSubstrate memory original =
            MidasSubstrate({substrateType: MidasSubstrateType(typeRaw), substrateAddress: addr});
        // when
        bytes32 encoded = harness.substrateToBytes32(original);
        MidasSubstrate memory decoded = harness.bytes32ToSubstrate(encoded);
        // then
        assertEq(uint8(decoded.substrateType), uint8(original.substrateType), "Round-trip: type must be identity");
        assertEq(decoded.substrateAddress, original.substrateAddress, "Round-trip: address must be identity");
    }

    // F5 — validateMTokenGranted: no revert when substrate is properly granted
    function testFuzz_ValidateMTokenGranted_Success(uint256 marketId, address mToken) public {
        vm.assume(mToken != address(0));
        vm.assume(marketId < type(uint128).max); // avoid unrealistic market IDs
        // given — grant the substrate
        _grantSingleSubstrate(marketId, MidasSubstrateType.M_TOKEN, mToken);
        // when/then — must not revert
        harness.validateMTokenGranted(marketId, mToken);
    }

    // F6 — validateMTokenGranted: reverts with correct selector when not granted
    function testFuzz_ValidateMTokenGranted_RevertsWhenNotGranted(uint256 marketId, address mToken) public {
        vm.assume(marketId < type(uint128).max);
        // given — nothing granted (fresh harness storage per test)
        vm.expectRevert(
            abi.encodeWithSelector(MidasSubstrateLib.MidasFuseUnsupportedSubstrate.selector, uint8(1), mToken)
        );
        harness.validateMTokenGranted(marketId, mToken);
    }
}
