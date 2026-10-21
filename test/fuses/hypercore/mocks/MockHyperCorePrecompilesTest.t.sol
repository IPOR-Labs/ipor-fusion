// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {HyperCoreTestHelper} from "../HyperCoreTestHelper.sol";
import {HyperCoreHip3RawFixtures} from "../fixtures/HyperCoreHip3RawFixtures.sol";
import {HyperCoreLib} from "../../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {MockCoreWriter} from "./MockCoreWriter.sol";
import {HyperCoreMockState} from "./MockHyperCorePrecompiles.sol";

/// @title MockHyperCorePrecompilesTest
/// @notice Proves the etched HyperCore precompile mocks answer raw (non-selector) abi-encoded input
/// at the correct addresses, and that MockCoreWriter records raw action bytes. Also pins the address
/// map: 0x806 markPx and 0x809 l1BlockNumber must not be swapped (see chat/EXECUTION.md correction).
contract MockHyperCorePrecompilesTest is Test {
    address internal constant POSITION = 0x0000000000000000000000000000000000000800;
    address internal constant SPOT_BALANCE = 0x0000000000000000000000000000000000000801;
    address internal constant WITHDRAWABLE = 0x0000000000000000000000000000000000000803;
    address internal constant MARK_PX = 0x0000000000000000000000000000000000000806;
    address internal constant ORACLE_PX = 0x0000000000000000000000000000000000000807;
    address internal constant L1_BLOCK_NUMBER = 0x0000000000000000000000000000000000000809;
    address internal constant PERP_ASSET_INFO = address(uint160(0x80A));
    address internal constant TOKEN_INFO = address(uint160(0x80C));
    address internal constant ACCOUNT_MARGIN_SUMMARY = address(uint160(0x80F));
    address internal constant CORE_USER_EXISTS = 0x0000000000000000000000000000000000000810;
    address internal constant POSITION2 = address(uint160(0x813));

    HyperCoreMockState internal state;
    MockCoreWriter internal coreWriter;

    address internal user = makeAddr("user");

    function setUp() public {
        state = HyperCoreTestHelper.etchPrecompiles(vm);
        coreWriter = HyperCoreTestHelper.etchCoreWriter(vm);
    }

    function testPositionAnswersAt0x800() public {
        state.setPosition(
            user,
            0,
            HyperCoreMockState.Position({szi: 100, entryNtl: 200, isolatedRawUsd: 0, leverage: 5, isIsolated: false})
        );

        (bool ok, bytes memory ret) = POSITION.staticcall(abi.encode(user, uint32(0)));
        assertTrue(ok, "position call failed");

        HyperCoreMockState.Position memory position = abi.decode(ret, (HyperCoreMockState.Position));
        assertEq(position.szi, 100);
        assertEq(position.entryNtl, 200);
        assertEq(position.leverage, 5);
        assertFalse(position.isIsolated);
    }

    function testSpotBalanceAnswersAt0x801() public {
        state.setSpotBalance(user, 0, HyperCoreMockState.SpotBalance({total: 1_000e8, hold: 100e8, entryNtl: 0}));

        (bool ok, bytes memory ret) = SPOT_BALANCE.staticcall(abi.encode(user, uint64(0)));
        assertTrue(ok, "spotBalance call failed");

        HyperCoreMockState.SpotBalance memory balance = abi.decode(ret, (HyperCoreMockState.SpotBalance));
        assertEq(balance.total, 1_000e8);
        assertEq(balance.hold, 100e8);
    }

    function testWithdrawableAnswersAt0x803() public {
        state.setWithdrawable(user, 42);

        (bool ok, bytes memory ret) = WITHDRAWABLE.staticcall(abi.encode(user));
        assertTrue(ok, "withdrawable call failed");
        assertEq(abi.decode(ret, (uint64)), 42);
    }

    /// @dev Pins the address map so a future refactor cannot silently swap markPx (0x806) and
    /// l1BlockNumber (0x809), as happened in the production lib per chat/EXECUTION.md.
    function testMarkPxAnswersAt0x806NotL1BlockNumber() public {
        state.setMarkPx(0, 111_000e8);
        state.setL1BlockNumber(999);

        (bool ok, bytes memory ret) = MARK_PX.staticcall(abi.encode(uint32(0)));
        assertTrue(ok, "markPx call failed");
        assertEq(abi.decode(ret, (uint64)), 111_000e8, "0x806 must answer markPx, not l1BlockNumber");
    }

    function testOraclePxAnswersAt0x807() public {
        state.setOraclePx(0, 110_500e8);

        (bool ok, bytes memory ret) = ORACLE_PX.staticcall(abi.encode(uint32(0)));
        assertTrue(ok, "oraclePx call failed");
        assertEq(abi.decode(ret, (uint64)), 110_500e8);
    }

    /// @dev Pins the address map so a future refactor cannot silently swap l1BlockNumber (0x809) and
    /// markPx (0x806), as happened in the production lib per chat/EXECUTION.md.
    function testL1BlockNumberAnswersAt0x809NotMarkPx() public {
        state.setMarkPx(0, 111_000e8);
        state.setL1BlockNumber(999);

        (bool ok, bytes memory ret) = L1_BLOCK_NUMBER.staticcall("");
        assertTrue(ok, "l1BlockNumber call failed");
        assertEq(abi.decode(ret, (uint64)), 999, "0x809 must answer l1BlockNumber, not markPx");
    }

    function testPerpAssetInfoAnswersAt0x80A() public view {
        (bool ok, bytes memory ret) = PERP_ASSET_INFO.staticcall(abi.encode(uint32(0)));
        assertTrue(ok, "perpAssetInfo call failed");

        HyperCoreMockState.PerpAssetInfo memory info = abi.decode(ret, (HyperCoreMockState.PerpAssetInfo));
        assertEq(info.coin, "BTC");
        assertEq(info.szDecimals, 5);
        assertEq(info.maxLeverage, 40);
    }

    function testTokenInfoAnswersAt0x80CForToken0() public view {
        (bool ok, bytes memory ret) = TOKEN_INFO.staticcall(abi.encode(uint64(0)));
        assertTrue(ok, "tokenInfo call failed");

        HyperCoreMockState.TokenInfo memory info = abi.decode(ret, (HyperCoreMockState.TokenInfo));
        assertEq(info.name, "USDC");
        assertEq(info.szDecimals, 8);
        assertEq(info.weiDecimals, 8);
        assertEq(info.evmExtraWeiDecimals, -2);
    }

    function testAccountMarginSummaryAnswersAt0x80F() public {
        state.setAccountMarginSummary(
            0,
            user,
            HyperCoreMockState.AccountMarginSummary({accountValue: 1_000e6, marginUsed: 100e6, ntlPos: 500e6, rawUsd: 900e6})
        );

        (bool ok, bytes memory ret) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(0), user));
        assertTrue(ok, "accountMarginSummary call failed");

        HyperCoreMockState.AccountMarginSummary memory summary = abi.decode(ret, (HyperCoreMockState.AccountMarginSummary));
        assertEq(summary.accountValue, 1_000e6);
        assertEq(summary.marginUsed, 100e6);
    }

    function testCoreUserExistsAnswersAt0x810() public {
        assertFalse(_coreUserExists(user));

        state.setCoreUserExists(user, true);
        assertTrue(_coreUserExists(user));
    }

    function testForcedFailureRevertsAtGivenPrecompile() public {
        state.setFail(POSITION, true);

        (bool ok, ) = POSITION.staticcall(abi.encode(user, uint32(0)));
        assertFalse(ok, "position should revert when forced to fail");

        // Other precompiles are unaffected.
        (bool otherOk, ) = WITHDRAWABLE.staticcall(abi.encode(user));
        assertTrue(otherOk, "withdrawable should not be affected by position's forced failure");
    }

    function testUnknownPrecompileAddressReverts() public view {
        address unknown = 0x0000000000000000000000000000000000000802;
        (bool ok, ) = unknown.staticcall(abi.encode(user));
        assertFalse(ok, "unimplemented precompile in range must revert");
    }

    function testMockCoreWriterRecordsRawActionBytes() public {
        bytes memory action = abi.encodePacked(uint8(1), uint8(0), uint8(0), uint8(1), abi.encode(uint256(42)));

        (bool ok, ) = HyperCoreTestHelper.CORE_WRITER.call(abi.encodeWithSelector(MockCoreWriter.sendRawAction.selector, action));
        assertTrue(ok, "sendRawAction call failed");

        assertEq(coreWriter.callCount(), 1);
        assertEq(coreWriter.lastAction(), action);

        (uint8 version, uint24 actionId, bytes memory payload) = coreWriter.decodeHeader(coreWriter.lastAction());
        assertEq(version, 1);
        assertEq(actionId, 1);
        assertEq(abi.decode(payload, (uint256)), 42);
    }

    function _coreUserExists(address who) internal view returns (bool) {
        (bool ok, bytes memory ret) = CORE_USER_EXISTS.staticcall(abi.encode(who));
        assertTrue(ok, "coreUserExists call failed");
        return abi.decode(ret, (bool));
    }

    // -------------------------------------------------------------------
    // HIP-3 / position2 (0x813) behaviour
    // -------------------------------------------------------------------

    uint32 internal constant NVDA_READ_INDEX = 10002;
    uint32 internal constant SOXL_READ_INDEX = 10107;
    uint32 internal constant PARA_TOTAL2_READ_INDEX = 80000;
    uint32 internal constant UNREGISTERED_HIP3_READ_INDEX = 10003;

    function _registerHip3Market(uint32 readIndex, string memory coin) internal {
        state.setPerpAssetInfo(
            readIndex,
            HyperCoreMockState.PerpAssetInfo({coin: coin, marginTableId: 1, szDecimals: 2, maxLeverage: 10, onlyIsolated: false})
        );
    }

    /// @dev D.1 — position2 answers at 0x813 with the value set through `setPosition`, for a native
    /// index and for a registered HIP-3 index (10002).
    function testPosition2AnswersAt0x813ForNativeAndRegisteredHip3Index() public {
        state.setPosition(
            user,
            0,
            HyperCoreMockState.Position({szi: 100, entryNtl: 200, isolatedRawUsd: 0, leverage: 5, isIsolated: false})
        );
        (bool nativeOk, bytes memory nativeRet) = POSITION2.staticcall(abi.encode(user, uint32(0)));
        assertTrue(nativeOk, "position2 native read failed");
        HyperCoreMockState.Position memory nativePosition = abi.decode(nativeRet, (HyperCoreMockState.Position));
        assertEq(nativePosition.szi, 100);
        assertEq(nativePosition.entryNtl, 200);

        _registerHip3Market(NVDA_READ_INDEX, "xyz:NVDA");
        state.setPosition(
            user,
            NVDA_READ_INDEX,
            HyperCoreMockState.Position({szi: 586112, entryNtl: 131686580850, isolatedRawUsd: 0, leverage: 20, isIsolated: false})
        );
        (bool hip3Ok, bytes memory hip3Ret) = POSITION2.staticcall(abi.encode(user, NVDA_READ_INDEX));
        assertTrue(hip3Ok, "position2 HIP-3 read failed");
        HyperCoreMockState.Position memory hip3Position = abi.decode(hip3Ret, (HyperCoreMockState.Position));
        assertEq(hip3Position.szi, 586112);
        assertEq(hip3Position.entryNtl, 131686580850);
        assertEq(hip3Position.leverage, 20);
    }

    /// @dev D.2 — legacy 0x800 answers for read index 10002 (registered) and reverts for 80000 even
    /// when registered; 0x813 answers for 80000 when registered.
    function testLegacyPositionRevertsAboveUint16ButPosition2Answers() public {
        _registerHip3Market(NVDA_READ_INDEX, "xyz:NVDA");
        (bool legacyNvdaOk, ) = POSITION.staticcall(abi.encode(user, NVDA_READ_INDEX));
        assertTrue(legacyNvdaOk, "legacy position should answer for read index <= uint16 max");

        _registerHip3Market(PARA_TOTAL2_READ_INDEX, "para:TOTAL2");
        (bool legacyParaOk, ) = POSITION.staticcall(abi.encode(user, PARA_TOTAL2_READ_INDEX));
        assertFalse(legacyParaOk, "legacy position must revert above uint16 max even when registered");

        (bool position2ParaOk, ) = POSITION2.staticcall(abi.encode(user, PARA_TOTAL2_READ_INDEX));
        assertTrue(position2ParaOk, "position2 must answer above uint16 max when registered");
    }

    /// @dev D.3 — unregistered HIP-3 index reverts on 0x800, 0x813, 0x806, 0x807, 0x80A; after
    /// `setPerpAssetInfo` it answers on all of them.
    function testUnregisteredHip3IndexRevertsThenAnswersAfterRegistration() public {
        (bool positionOk, ) = POSITION.staticcall(abi.encode(user, UNREGISTERED_HIP3_READ_INDEX));
        assertFalse(positionOk, "0x800 must revert for unregistered HIP-3 index");
        (bool position2Ok, ) = POSITION2.staticcall(abi.encode(user, UNREGISTERED_HIP3_READ_INDEX));
        assertFalse(position2Ok, "0x813 must revert for unregistered HIP-3 index");
        (bool markPxOk, ) = MARK_PX.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertFalse(markPxOk, "0x806 must revert for unregistered HIP-3 index");
        (bool oraclePxOk, ) = ORACLE_PX.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertFalse(oraclePxOk, "0x807 must revert for unregistered HIP-3 index");
        (bool perpAssetInfoOk, ) = PERP_ASSET_INFO.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertFalse(perpAssetInfoOk, "0x80A must revert for unregistered HIP-3 index");

        _registerHip3Market(UNREGISTERED_HIP3_READ_INDEX, "xyz:TEST");

        (bool positionOkAfter, ) = POSITION.staticcall(abi.encode(user, UNREGISTERED_HIP3_READ_INDEX));
        assertTrue(positionOkAfter, "0x800 must answer once registered");
        (bool position2OkAfter, ) = POSITION2.staticcall(abi.encode(user, UNREGISTERED_HIP3_READ_INDEX));
        assertTrue(position2OkAfter, "0x813 must answer once registered");
        (bool markPxOkAfter, ) = MARK_PX.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertTrue(markPxOkAfter, "0x806 must answer once registered");
        (bool oraclePxOkAfter, ) = ORACLE_PX.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertTrue(oraclePxOkAfter, "0x807 must answer once registered");
        (bool perpAssetInfoOkAfter, ) = PERP_ASSET_INFO.staticcall(abi.encode(UNREGISTERED_HIP3_READ_INDEX));
        assertTrue(perpAssetInfoOkAfter, "0x80A must answer once registered");
    }

    /// @dev D.4 — a native index that was never configured still returns defaults (no revert) on
    /// 0x806, 0x807, 0x80A, 0x800.
    function testNeverConfiguredNativeIndexReturnsDefaults() public view {
        uint32 neverConfiguredNativeIndex = 42;

        (bool positionOk, bytes memory positionRet) = POSITION.staticcall(abi.encode(user, neverConfiguredNativeIndex));
        assertTrue(positionOk, "0x800 must answer for an unconfigured native index");
        HyperCoreMockState.Position memory position = abi.decode(positionRet, (HyperCoreMockState.Position));
        assertEq(position.szi, 0);

        (bool markPxOk, bytes memory markPxRet) = MARK_PX.staticcall(abi.encode(neverConfiguredNativeIndex));
        assertTrue(markPxOk, "0x806 must answer for an unconfigured native index");
        assertEq(abi.decode(markPxRet, (uint64)), 0);

        (bool oraclePxOk, bytes memory oraclePxRet) = ORACLE_PX.staticcall(abi.encode(neverConfiguredNativeIndex));
        assertTrue(oraclePxOk, "0x807 must answer for an unconfigured native index");
        assertEq(abi.decode(oraclePxRet, (uint64)), 0);

        (bool perpAssetInfoOk, bytes memory perpAssetInfoRet) =
            PERP_ASSET_INFO.staticcall(abi.encode(neverConfiguredNativeIndex));
        assertTrue(perpAssetInfoOk, "0x80A must answer for an unconfigured native index");
        HyperCoreMockState.PerpAssetInfo memory info = abi.decode(perpAssetInfoRet, (HyperCoreMockState.PerpAssetInfo));
        assertEq(bytes(info.coin).length, 0);
    }

    /// @dev D.5 — accountMarginSummary: dex 0, 1, 6, 8, 9, 10 without state return four zero words;
    /// dex 11 and `type(uint32).max` revert.
    function testAccountMarginSummaryDexRangeAndRevertAboveMax() public view {
        uint32[6] memory validDexesWithoutState = [uint32(0), 1, 6, 8, 9, 10];
        for (uint256 i; i < validDexesWithoutState.length; ++i) {
            (bool ok, bytes memory ret) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(validDexesWithoutState[i], user));
            assertTrue(ok, "accountMarginSummary must answer for valid dexes without state");
            HyperCoreMockState.AccountMarginSummary memory summary =
                abi.decode(ret, (HyperCoreMockState.AccountMarginSummary));
            assertEq(summary.accountValue, 0);
            assertEq(summary.marginUsed, 0);
            assertEq(summary.ntlPos, 0);
            assertEq(summary.rawUsd, 0);
        }

        (bool elevenOk, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(11), user));
        assertFalse(elevenOk, "accountMarginSummary must revert for dex 11");

        (bool maxOk, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(type(uint32).max, user));
        assertFalse(maxOk, "accountMarginSummary must revert for type(uint32).max");
    }

    /// @dev D.6 — per-dex failure switch: with failure set for dex 1, a dex 1 read reverts while
    /// dex 0 and dex 8 still answer; clearing the switch restores dex 1.
    function testAccountMarginSummaryPerDexFailureSwitch() public {
        state.setAccountMarginSummaryFail(1, true);

        (bool dex1Ok, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(1), user));
        assertFalse(dex1Ok, "dex 1 must revert while its failure switch is set");

        (bool dex0Ok, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(0), user));
        assertTrue(dex0Ok, "dex 0 must still answer while dex 1's failure switch is set");

        (bool dex8Ok, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(8), user));
        assertTrue(dex8Ok, "dex 8 must still answer while dex 1's failure switch is set");

        state.setAccountMarginSummaryFail(1, false);

        (bool dex1RestoredOk, ) = ACCOUNT_MARGIN_SUMMARY.staticcall(abi.encode(uint32(1), user));
        assertTrue(dex1RestoredOk, "dex 1 must answer again once its failure switch is cleared");
    }

    /// @dev D.7 — trailing calldata is ignored: `0x807` called with
    /// `abi.encode(uint32(1), uint32(2))` returns the oracle price stored for native index 1.
    function testOraclePxIgnoresTrailingCalldata() public {
        state.setOraclePx(1, 223_930);

        (bool ok, bytes memory ret) = ORACLE_PX.staticcall(abi.encode(uint32(1), uint32(2)));
        assertTrue(ok, "oraclePx call with trailing calldata failed");
        assertEq(abi.decode(ret, (uint64)), 223_930);
    }

    /// @dev D.8 — every raw fixture decodes to the values stated in the task.
    function testHip3RawFixturesDecodeToStatedValues() public pure {
        HyperCoreLib.PerpAssetInfo memory nvda =
            abi.decode(HyperCoreHip3RawFixtures.perpAssetInfoXyzNvda(), (HyperCoreLib.PerpAssetInfo));
        assertEq(nvda.coin, "xyz:NVDA");
        assertEq(nvda.marginTableId, 20);
        assertEq(nvda.szDecimals, 3);
        assertEq(nvda.maxLeverage, 20);
        assertFalse(nvda.onlyIsolated);

        HyperCoreLib.PerpAssetInfo memory soxl =
            abi.decode(HyperCoreHip3RawFixtures.perpAssetInfoXyzSoxl(), (HyperCoreLib.PerpAssetInfo));
        assertEq(soxl.coin, "xyz:SOXL");
        assertEq(soxl.marginTableId, 10);
        assertEq(soxl.szDecimals, 2);
        assertEq(soxl.maxLeverage, 10);
        assertTrue(soxl.onlyIsolated);

        HyperCoreLib.PerpAssetInfo memory paraTotal2 =
            abi.decode(HyperCoreHip3RawFixtures.perpAssetInfoParaTotal2(), (HyperCoreLib.PerpAssetInfo));
        assertEq(paraTotal2.coin, "para:TOTAL2");
        assertEq(paraTotal2.marginTableId, 20);
        assertEq(paraTotal2.szDecimals, 3);
        assertEq(paraTotal2.maxLeverage, 20);
        assertFalse(paraTotal2.onlyIsolated);

        HyperCoreLib.PerpAssetInfo memory ioAnth =
            abi.decode(HyperCoreHip3RawFixtures.perpAssetInfoIoAnth(), (HyperCoreLib.PerpAssetInfo));
        assertEq(ioAnth.coin, "io:ANTH");
        assertEq(ioAnth.marginTableId, 6);
        assertEq(ioAnth.szDecimals, 3);
        assertEq(ioAnth.maxLeverage, 6);
        assertTrue(ioAnth.onlyIsolated);

        (int64 accountValue, uint64 marginUsed, uint64 ntlPos, int64 rawUsd) =
            abi.decode(HyperCoreHip3RawFixtures.accountMarginSummaryXyzHolder(), (int64, uint64, uint64, int64));
        assertEq(accountValue, 9386090926);
        assertEq(marginUsed, 8592359262);
        assertEq(ntlPos, 159999504640);
        assertEq(rawUsd, -150613413714);
    }

    /// @dev D.9 — arithmetic identity of the fixture snapshot, computed in the test.
    function testHip3FixtureSnapshotArithmeticIdentity() public pure {
        int256 nvdaNotional = int256(HyperCoreHip3RawFixtures.nvdaPositionSzi()) * int256(uint256(HyperCoreHip3RawFixtures.nvdaMarkPx()));
        int256 soxlNotional = int256(HyperCoreHip3RawFixtures.soxlPositionSzi()) * int256(uint256(HyperCoreHip3RawFixtures.soxlMarkPx()));

        assertEq(nvdaNotional + soxlNotional + int256(-150613413714), int256(9386090926));
        assertEq(nvdaNotional + soxlNotional, int256(159999504640));
    }
}
