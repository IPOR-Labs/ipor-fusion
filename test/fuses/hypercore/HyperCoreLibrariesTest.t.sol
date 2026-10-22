// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {HyperCoreRawFixtures} from "./fixtures/HyperCoreRawFixtures.sol";

contract HyperCoreLibHarness {
    function limit() external pure returns (bytes memory) {
        return HyperCoreLib.encodeLimitOrder(1, true, 123_000_000, 250_000_000, false, HyperCoreLib.TIF_IOC, 77);
    }

    function cancelOid() external pure returns (bytes memory) {
        return HyperCoreLib.encodeCancelByOid(1, 0x1234);
    }

    function cancelCloid() external pure returns (bytes memory) {
        return HyperCoreLib.encodeCancelByCloid(1, 0x1234);
    }

    function spotSend() external pure returns (bytes memory) {
        return HyperCoreLib.encodeSpotSend(address(0xA1), 3, 0x4567);
    }

    function classTransfer() external pure returns (bytes memory) {
        return HyperCoreLib.encodeUsdClassTransfer(12_345_678, true);
    }

    function builderFee() external pure returns (bytes memory) {
        return HyperCoreLib.encodeApproveBuilderFee(123, address(0xB2));
    }

    function sendAsset() external pure returns (bytes memory) {
        return HyperCoreLib.encodeSendAsset(address(0xA1), address(0), type(uint32).max, 0, 0, 1e8);
    }

    function toCore(uint256 amount_, int8 extra_) external pure returns (uint64, uint256) {
        return HyperCoreLib.evmToCoreWei(amount_, extra_);
    }

    function toEvm(uint64 amount_, int8 extra_) external pure returns (uint256) {
        return HyperCoreLib.coreWeiToEvm(amount_, extra_);
    }

    function readSpot(address user_, uint64 token_) external view returns (HyperCoreLib.SpotBalance memory) {
        return HyperCoreLib.spotBalance(user_, token_);
    }

    function readMargin(uint32 dex_, address user_) external view returns (HyperCoreLib.AccountMarginSummary memory) {
        return HyperCoreLib.accountMarginSummary(dex_, user_);
    }

    function readToken(uint64 token_) external view returns (HyperCoreLib.TokenInfo memory) {
        return HyperCoreLib.tokenInfo(token_);
    }

    function readPerpAsset(uint32 asset_) external view returns (HyperCoreLib.PerpAssetInfo memory) {
        return HyperCoreLib.perpAssetInfo(asset_);
    }

    function readUserExists(address user_) external view returns (bool) {
        return HyperCoreLib.coreUserExists(user_);
    }

    function readWithdrawable(address user_) external view returns (uint64) {
        return HyperCoreLib.withdrawable(user_);
    }

    function readPosition(address user_, uint32 asset_) external view returns (HyperCoreLib.Position memory) {
        return HyperCoreLib.position(user_, asset_);
    }

    function readOraclePx(uint32 asset_) external view returns (uint64) {
        return HyperCoreLib.oraclePx(asset_);
    }

    function readMarkPx(uint32 asset_) external view returns (uint64) {
        return HyperCoreLib.markPx(asset_);
    }

    function readL1Block() external view returns (uint64) {
        return HyperCoreLib.l1BlockNumber();
    }

    function notional(uint64 size_, uint64 price_) external pure returns (uint256) {
        return HyperCoreLib.notionalUsd6(size_, price_);
    }

    function perpPxToPx1e8(uint64 rawPx_, uint8 szDecimals_) external pure returns (uint256) {
        return HyperCoreLib.perpPxToPx1e8(rawPx_, szDecimals_);
    }

    function lot(uint8 decimals_) external pure returns (uint64) {
        return HyperCoreLib.lotOf(decimals_);
    }

    function push(bytes memory raw_) external {
        HyperCoreLib.sendRawAction(raw_);
    }
}

contract HyperCoreSubstrateHarness {
    function grant(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function spotTokens(uint256 marketId_) external view returns (uint64[] memory, address[] memory) {
        return HyperCoreSubstrateLib.getSpotTokens(marketId_);
    }

    function config(uint256 marketId_, HyperCoreSubstrateLib.ConfigKey key_) external view returns (bool, uint240) {
        return HyperCoreSubstrateLib.getConfig(marketId_, key_);
    }

    function destination(address destination_) external pure returns (address) {
        return HyperCoreSubstrateLib.decodeDestination(HyperCoreSubstrateLib.encodeDestination(destination_));
    }

    function getSpot(uint64 index_, address asset_) external pure returns (uint64, address) {
        return HyperCoreSubstrateLib.decodeSpotToken(HyperCoreSubstrateLib.encodeSpotToken(index_, asset_));
    }

    function getPerp(uint32 asset_, uint88 cap_, bool reduceOnly_) external pure returns (uint32, uint88, bool) {
        return
            HyperCoreSubstrateLib.decodePerpMarket(HyperCoreSubstrateLib.encodePerpMarket(asset_, cap_, reduceOnly_));
    }

    function getBuilder(address builder_, uint64 cap_) external pure returns (address, uint64) {
        return HyperCoreSubstrateLib.decodeBuilder(HyperCoreSubstrateLib.encodeBuilder(builder_, cap_));
    }

    function getConfig(
        HyperCoreSubstrateLib.ConfigKey key_,
        uint240 value_
    ) external pure returns (HyperCoreSubstrateLib.ConfigKey, uint240) {
        return HyperCoreSubstrateLib.decodeConfig(HyperCoreSubstrateLib.encodeConfig(key_, value_));
    }

    function getSendCap(uint64 index_, uint128 cap_) external pure returns (uint64, uint128) {
        return HyperCoreSubstrateLib.decodeSendCap(HyperCoreSubstrateLib.encodeSendCap(index_, cap_));
    }

    function lookupSpot(uint256 marketId_, uint64 index_) external view returns (bool, address) {
        return HyperCoreSubstrateLib.getSpotToken(marketId_, index_);
    }

    function lookupPerp(uint256 marketId_, uint32 asset_) external view returns (bool, uint88, bool) {
        return HyperCoreSubstrateLib.getPerpMarket(marketId_, asset_);
    }

    function lookupDestination(uint256 marketId_, address destination_) external view returns (bool) {
        return HyperCoreSubstrateLib.isDestinationGranted(marketId_, destination_);
    }

    function lookupBuilder(uint256 marketId_, address builder_) external view returns (bool, uint64) {
        return HyperCoreSubstrateLib.getBuilder(marketId_, builder_);
    }

    function lookupSendCap(uint256 marketId_, uint64 index_) external view returns (bool, uint128) {
        return HyperCoreSubstrateLib.getSendCap(marketId_, index_);
    }

    function decodeDestination(bytes32 substrate_) external pure returns (address) {
        return HyperCoreSubstrateLib.decodeDestination(substrate_);
    }

    function decodeSendCap(bytes32 substrate_) external pure returns (uint64, uint128) {
        return HyperCoreSubstrateLib.decodeSendCap(substrate_);
    }

    function decodeConfig(bytes32 substrate_) external pure returns (HyperCoreSubstrateLib.ConfigKey, uint240) {
        return HyperCoreSubstrateLib.decodeConfig(substrate_);
    }
}

contract HyperCoreCoreWriterMock {
    bytes public lastData;

    function sendRawAction(bytes calldata data_) external {
        lastData = data_;
    }
}

contract HyperCoreLibrariesTest is Test {
    HyperCoreLibHarness private _lib;
    HyperCoreSubstrateHarness private _substrate;

    function setUp() public {
        _lib = new HyperCoreLibHarness();
        _substrate = new HyperCoreSubstrateHarness();
    }

    function testPrecompileAddressesArePinned() public pure {
        assertEq(HyperCoreLib.POSITION_PRECOMPILE, address(0x800));
        assertEq(HyperCoreLib.SPOT_BALANCE_PRECOMPILE, address(0x801));
        assertEq(HyperCoreLib.WITHDRAWABLE_PRECOMPILE, address(0x803));
        assertEq(HyperCoreLib.MARK_PX_PRECOMPILE, address(0x806));
        assertEq(HyperCoreLib.ORACLE_PX_PRECOMPILE, address(0x807));
        assertEq(HyperCoreLib.L1_BLOCK_NUMBER_PRECOMPILE, address(0x809));
        assertEq(HyperCoreLib.PERP_ASSET_INFO_PRECOMPILE, address(0x80A));
        assertEq(HyperCoreLib.TOKEN_INFO_PRECOMPILE, address(0x80C));
        assertEq(HyperCoreLib.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE, address(0x80F));
        assertEq(HyperCoreLib.CORE_USER_EXISTS_PRECOMPILE, address(0x810));
        assertEq(HyperCoreLib.CORE_WRITER, address(0x3333333333333333333333333333333333333333));
    }

    function testLimitActionGoldenEncoding() public view {
        bytes memory expected = abi.encodePacked(
            bytes1(0x01),
            bytes3(uint24(1)),
            abi.encode(uint32(1), true, uint64(123_000_000), uint64(250_000_000), false, uint8(3), uint128(77))
        );
        assertEq(_lib.limit(), expected);
    }

    function testCancelActionIdsAndPayloads() public view {
        assertEq(
            _lib.cancelOid(),
            abi.encodePacked(bytes1(uint8(1)), bytes3(uint24(10)), abi.encode(uint32(1), uint64(0x1234)))
        );
        assertEq(
            _lib.cancelCloid(),
            abi.encodePacked(bytes1(uint8(1)), bytes3(uint24(11)), abi.encode(uint32(1), uint128(0x1234)))
        );
    }

    function testSpotSendClassTransferAndBuilderFeeGoldenEncodings() public view {
        assertEq(
            _lib.spotSend(),
            abi.encodePacked(bytes1(uint8(1)), bytes3(uint24(6)), abi.encode(address(0xA1), uint64(3), uint64(0x4567)))
        );
        assertEq(
            _lib.classTransfer(),
            abi.encodePacked(bytes1(uint8(1)), bytes3(uint24(7)), abi.encode(uint64(12_345_678), true))
        );
        assertEq(
            _lib.builderFee(),
            abi.encodePacked(bytes1(uint8(1)), bytes3(uint24(12)), abi.encode(uint64(123), address(0xB2)))
        );
    }

    function testSendAssetGoldenEncodingIncludesZeroSubaccount() public view {
        assertEq(
            _lib.sendAsset(),
            abi.encodePacked(
                bytes1(uint8(1)),
                bytes3(uint24(13)),
                abi.encode(address(0xA1), address(0), type(uint32).max, uint32(0), uint64(0), uint64(1e8))
            )
        );
    }

    function testSendRawActionCallsCoreWriterFunctionSelector() public {
        bytes memory raw = hex"01000001";
        HyperCoreCoreWriterMock writer = new HyperCoreCoreWriterMock();
        vm.etch(HyperCoreLib.CORE_WRITER, address(writer).code);
        _lib.push(raw);
        assertEq(HyperCoreCoreWriterMock(HyperCoreLib.CORE_WRITER).lastData(), raw);
    }

    function testSystemAddressDoesNotAssumeNetworkSpecificTokenIndex() public pure {
        assertEq(HyperCoreLib.systemAddress(0), address(0x2000000000000000000000000000000000000000));
        assertEq(HyperCoreLib.systemAddress(1), address(0x2000000000000000000000000000000000000001));
        assertEq(HyperCoreLib.systemAddress(150), address(0x2000000000000000000000000000000000000096));
    }

    function testSpotBalancePrecompileReadDecodesTotalHoldAndEntryNotional() public {
        address vault = address(0xCAFE);
        vm.mockCall(
            HyperCoreLib.SPOT_BALANCE_PRECOMPILE,
            abi.encode(vault, uint64(0)),
            abi.encode(uint64(100), uint64(25), uint64(75))
        );
        HyperCoreLib.SpotBalance memory balance = _lib.readSpot(vault, 0);
        assertEq(balance.total, 100);
        assertEq(balance.hold, 25);
        assertEq(balance.entryNtl, 75);
    }

    function testAccountMarginSummaryUsesPerpDexAndAddressAndKeepsSignedValues() public {
        address vault = address(0xCAFE);
        vm.mockCall(
            HyperCoreLib.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(uint32(0), vault),
            abi.encode(int64(-123), uint64(456), uint64(789), int64(-321))
        );
        HyperCoreLib.AccountMarginSummary memory summary = _lib.readMargin(0, vault);
        assertEq(summary.accountValue, -123);
        assertEq(summary.marginUsed, 456);
        assertEq(summary.ntlPos, 789);
        assertEq(summary.rawUsd, -321);
    }

    function testTokenInfoPrecompileReadDecodesDynamicFieldsAndSignedDecimals() public {
        uint64[] memory spotIndices = new uint64[](2);
        spotIndices[0] = 1;
        spotIndices[1] = 3;
        address evmToken = address(0xBEEF);
        vm.mockCall(
            HyperCoreLib.TOKEN_INFO_PRECOMPILE,
            abi.encode(uint64(1)),
            abi.encode(
                HyperCoreLib.TokenInfo({
                    name: "TEST",
                    spots: spotIndices,
                    deployerTradingFeeShare: 7,
                    deployer: address(0x1234),
                    evmContract: evmToken,
                    szDecimals: 8,
                    weiDecimals: 8,
                    evmExtraWeiDecimals: -2
                })
            )
        );
        HyperCoreLib.TokenInfo memory info = _lib.readToken(1);
        assertEq(info.name, "TEST");
        assertEq(info.spots.length, 2);
        assertEq(info.spots[1], 3);
        assertEq(info.deployerTradingFeeShare, 7);
        assertEq(info.deployer, address(0x1234));
        assertEq(info.evmContract, evmToken);
        assertEq(info.weiDecimals, 8);
        assertEq(info.evmExtraWeiDecimals, -2);
    }

    function testMainnetTokenInfoRawFixtureDecodesSingleTupleWrapper() public {
        vm.mockCall(
            HyperCoreLib.TOKEN_INFO_PRECOMPILE,
            abi.encode(uint64(0)),
            HyperCoreRawFixtures.tokenInfoMainnetUsdc()
        );
        HyperCoreLib.TokenInfo memory info = _lib.readToken(0);
        assertEq(info.name, "USDC");
        assertEq(info.evmContract, address(0x6B9E773128f453f5c2C60935Ee2DE2CBc5390A24));
        assertEq(info.weiDecimals, 8);
        assertEq(info.evmExtraWeiDecimals, -2);
        assertEq(info.spots.length, 0);
    }

    function testPerpAssetInfoPrecompileReadDecodesLotMetadata() public {
        vm.mockCall(
            HyperCoreLib.PERP_ASSET_INFO_PRECOMPILE,
            abi.encode(uint32(1)),
            abi.encode(
                HyperCoreLib.PerpAssetInfo({
                    coin: "BTC",
                    marginTableId: 2,
                    szDecimals: 5,
                    maxLeverage: 40,
                    onlyIsolated: false
                })
            )
        );
        HyperCoreLib.PerpAssetInfo memory info = _lib.readPerpAsset(1);
        assertEq(info.coin, "BTC");
        assertEq(info.marginTableId, 2);
        assertEq(info.szDecimals, 5);
        assertEq(info.maxLeverage, 40);
        assertFalse(info.onlyIsolated);
    }

    function testMainnetPerpAssetInfoRawFixtureDecodesSingleTupleWrapper() public {
        vm.mockCall(
            HyperCoreLib.PERP_ASSET_INFO_PRECOMPILE,
            abi.encode(uint32(0)),
            HyperCoreRawFixtures.perpAssetInfoMainnetBtc()
        );
        HyperCoreLib.PerpAssetInfo memory info = _lib.readPerpAsset(0);
        assertEq(info.coin, "BTC");
        assertEq(info.marginTableId, 56);
        assertEq(info.szDecimals, 5);
        assertEq(info.maxLeverage, 40);
        assertFalse(info.onlyIsolated);
    }

    function testPrecompileFailureHasTypedError() public {
        vm.mockCallRevert(HyperCoreLib.CORE_USER_EXISTS_PRECOMPILE, abi.encode(address(0xCAFE)), bytes("failed"));
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreLib.HyperCorePrecompileFailed.selector,
                HyperCoreLib.CORE_USER_EXISTS_PRECOMPILE
            )
        );
        _lib.readUserExists(address(0xCAFE));
    }

    function testSuccessfulEmptyPrecompileReturnHasTypedError() public {
        vm.etch(HyperCoreLib.WITHDRAWABLE_PRECOMPILE, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreLib.HyperCorePrecompileFailed.selector,
                HyperCoreLib.WITHDRAWABLE_PRECOMPILE
            )
        );
        _lib.readWithdrawable(address(0xCAFE));
    }

    function testRemainingPrecompileReadersUseExpectedInputsAndReturnTypes() public {
        address vault = address(0xCAFE);
        vm.mockCall(HyperCoreLib.WITHDRAWABLE_PRECOMPILE, abi.encode(vault), abi.encode(uint64(50)));
        assertEq(_lib.readWithdrawable(vault), 50);

        vm.mockCall(
            HyperCoreLib.POSITION_PRECOMPILE,
            abi.encode(vault, uint32(1)),
            abi.encode(int64(-2), uint64(30), int64(-4), uint32(10), true)
        );
        HyperCoreLib.Position memory pos = _lib.readPosition(vault, 1);
        assertEq(pos.szi, -2);
        assertEq(pos.entryNtl, 30);
        assertEq(pos.isolatedRawUsd, -4);
        assertEq(pos.leverage, 10);
        assertTrue(pos.isIsolated);

        vm.mockCall(HyperCoreLib.ORACLE_PX_PRECOMPILE, abi.encode(uint32(1)), abi.encode(uint64(100)));
        vm.mockCall(HyperCoreLib.MARK_PX_PRECOMPILE, abi.encode(uint32(1)), abi.encode(uint64(101)));
        vm.mockCall(HyperCoreLib.L1_BLOCK_NUMBER_PRECOMPILE, bytes(""), abi.encode(uint64(102)));
        assertEq(_lib.readOraclePx(1), 100);
        assertEq(_lib.readMarkPx(1), 101);
        assertEq(_lib.readL1Block(), 102);

        vm.mockCall(HyperCoreLib.CORE_USER_EXISTS_PRECOMPILE, abi.encode(vault), abi.encode(true));
        assertTrue(_lib.readUserExists(vault));
    }

    function testSignedEvmToCoreConversionAndRounding() public view {
        (uint64 coreWei, uint256 roundedEvm) = _lib.toCore(1_234_567, -2);
        assertEq(coreWei, 123_456_700);
        assertEq(roundedEvm, 1_234_567);

        (coreWei, roundedEvm) = _lib.toCore(123, 2);
        assertEq(coreWei, 1);
        assertEq(roundedEvm, 100);
        assertEq(_lib.toEvm(123_456_700, -2), 1_234_567);
        assertEq(_lib.toEvm(123, 2), 12_300);
    }

    function testOrderNotionalRoundsUpToUsd6() public view {
        assertEq(_lib.notional(1e8, 1e8), 1e6);
        assertEq(_lib.notional(1, 1), 1);
        assertEq(_lib.notional(10_000, 10_000), 1);
    }

    function testPerpPxToPx1e8ScalesBySzDecimals() public view {
        assertEq(_lib.perpPxToPx1e8(223970, 3), 22_397_000_000);
        assertEq(_lib.perpPxToPx1e8(400_000, 2), 40e8);
        assertEq(_lib.perpPxToPx1e8(400, 5), 40e8);
        assertEq(_lib.perpPxToPx1e8(40_000_000, 0), 40e8);
        assertEq(_lib.perpPxToPx1e8(1, 8), 1e10);
    }

    function testPerpPxToPx1e8RejectsSzDecimalsAboveEightAndDoesNotOverflow() public {
        assertEq(_lib.perpPxToPx1e8(type(uint64).max, 8), uint256(type(uint64).max) * 1e10);
        vm.expectRevert(HyperCoreLib.HyperCoreAmountNotRepresentable.selector);
        _lib.perpPxToPx1e8(1, 9);
    }

    function testLotUsesHyperCoreEightDecimalSizeConvention() public view {
        assertEq(_lib.lot(5), 1_000);
        assertEq(_lib.lot(8), 1);
    }

    function testDecimalExponentMinimumFailsWithTypedOverflowInsteadOfPanic() public {
        vm.expectRevert(HyperCoreLib.HyperCoreDecimalConversionOverflow.selector);
        _lib.toCore(1, type(int8).min);
    }

    function testConversionAndLotRangeErrorsAreTyped() public {
        vm.expectRevert(HyperCoreLib.HyperCoreDecimalConversionOverflow.selector);
        _lib.toCore(type(uint256).max, -1);
        vm.expectRevert(HyperCoreLib.HyperCoreDecimalConversionOverflow.selector);
        _lib.toCore(uint256(type(uint64).max) + 1, 0);
        vm.expectRevert(HyperCoreLib.HyperCoreAmountNotRepresentable.selector);
        _lib.lot(9);
    }

    function testSpotPerpBuilderConfigAndSendCapSubstratesRoundTrip() public view {
        (uint64 index, address asset) = _substrate.getSpot(7, address(0xCAFE));
        assertEq(index, 7);
        assertEq(asset, address(0xCAFE));
        (uint32 perpAsset, uint88 cap, bool reduceOnly) = _substrate.getPerp(42, 99_000_000, true);
        assertEq(perpAsset, 42);
        assertEq(cap, 99_000_000);
        assertTrue(reduceOnly);
        (address builder, uint64 feeCap) = _substrate.getBuilder(address(0xBEEF), 25);
        assertEq(builder, address(0xBEEF));
        assertEq(feeCap, 25);
        assertEq(_substrate.destination(address(0xD00D)), address(0xD00D));
        (HyperCoreSubstrateLib.ConfigKey key, uint240 value) = _substrate.getConfig(
            HyperCoreSubstrateLib.ConfigKey.SettlementMode,
            2
        );
        assertEq(uint8(key), uint8(HyperCoreSubstrateLib.ConfigKey.SettlementMode));
        assertEq(value, 2);
        (key, value) = _substrate.getConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        assertEq(uint8(key), 6, "new config must be appended without renumbering existing values");
        assertEq(value, 1);
        uint128 maxWei;
        (index, maxWei) = _substrate.getSendCap(0, type(uint128).max);
        assertEq(index, 0);
        assertEq(maxWei, type(uint128).max);
    }

    function testSpotSendBridgeConfigIsLookupableAndDisabledWhenMissing() public {
        (bool set, uint240 value) = _substrate.config(55, HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled);
        assertFalse(set);
        assertEq(value, 0);

        bytes32[] memory grants = new bytes32[](1);
        grants[0] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled, 1);
        _substrate.grant(55, grants);
        (set, value) = _substrate.config(55, HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled);
        assertTrue(set);
        assertEq(value, 1);
    }

    function testSpotTokenListKeepsOnlyTheFirstEntryForDuplicateIndex() public {
        bytes32[] memory grants = new bytes32[](3);
        grants[0] = HyperCoreSubstrateLib.encodeSpotToken(7, address(0xA1));
        grants[1] = HyperCoreSubstrateLib.encodeSpotToken(7, address(0xB2));
        grants[2] = HyperCoreSubstrateLib.encodeSpotToken(8, address(0xC3));
        _substrate.grant(55, grants);

        (uint64[] memory indexes, address[] memory assets) = _substrate.spotTokens(55);
        assertEq(indexes.length, 2);
        assertEq(indexes[0], 7);
        assertEq(assets[0], address(0xA1));
        assertEq(indexes[1], 8);
        assertEq(assets[1], address(0xC3));
    }

    function testDuplicateConfigKeyRevertsInsteadOfChoosingAmbiguously() public {
        bytes32[] memory grants = new bytes32[](2);
        grants[0] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 1);
        grants[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        _substrate.grant(55, grants);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSubstrateLib.HyperCoreDuplicateConfig.selector,
                HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds
            )
        );
        _substrate.config(55, HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds);
    }

    /// @dev IL-8543: `WindowOrderSeconds` and `SettlementMode` are reserved (ignored) but must keep their
    ///      numeric positions so vaults that already granted them still decode and later keys do not shift.
    function testReservedConfigKeysKeepTheirNumbering() public pure {
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds), 1);
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.WindowOrderSeconds), 2, "reserved");
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6), 3);
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.PerpDexIds), 4);
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.SettlementMode), 5, "reserved");
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.SpotSendBridgeEnabled), 6);
    }

    function testGrantLookupsReturnFirstMatchingGrantAndFalseWhenMissing() public {
        bytes32[] memory grants = new bytes32[](5);
        grants[0] = HyperCoreSubstrateLib.encodeSpotToken(7, address(0xA1));
        grants[1] = HyperCoreSubstrateLib.encodePerpMarket(42, 99_000_000, true);
        grants[2] = HyperCoreSubstrateLib.encodeDestination(address(0xD00D));
        grants[3] = HyperCoreSubstrateLib.encodeBuilder(address(0xBEEF), 25);
        grants[4] = HyperCoreSubstrateLib.encodeSendCap(7, 1234);
        _substrate.grant(55, grants);

        (bool set, address asset) = _substrate.lookupSpot(55, 7);
        assertTrue(set);
        assertEq(asset, address(0xA1));
        (set, asset) = _substrate.lookupSpot(55, 8);
        assertFalse(set);
        assertEq(asset, address(0));
        uint88 notionalCap;
        bool reduceOnly;
        (set, notionalCap, reduceOnly) = _substrate.lookupPerp(55, 42);
        assertTrue(set);
        assertEq(notionalCap, 99_000_000);
        assertTrue(reduceOnly);
        assertTrue(_substrate.lookupDestination(55, address(0xD00D)));
        assertFalse(_substrate.lookupDestination(55, address(0xD00E)));
        uint64 builderCap;
        (set, builderCap) = _substrate.lookupBuilder(55, address(0xBEEF));
        assertTrue(set);
        assertEq(builderCap, 25);
        uint128 sendCap;
        (set, sendCap) = _substrate.lookupSendCap(55, 7);
        assertTrue(set);
        assertEq(sendCap, 1234);
        (set, sendCap) = _substrate.lookupSendCap(55, 8);
        assertFalse(set);
        assertEq(sendCap, 0);
    }

    function testSubstrateDecodersRejectWrongTypesAndReservedBits() public {
        bytes32 spot = HyperCoreSubstrateLib.encodeSpotToken(1, address(0xA1));
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidSubstrate.selector, spot));
        _substrate.decodeDestination(spot);
        bytes32 malformedSendCap = bytes32((uint256(6) << 248) | (uint256(1) << 240));
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidSubstrate.selector, malformedSendCap)
        );
        _substrate.decodeSendCap(malformedSendCap);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidConfigKey.selector, uint8(12)));
        _substrate.decodeConfig(bytes32((uint256(5) << 248) | (uint256(12) << 240)));
    }

    function testNewConfigKeysRoundTripAndUpperBoundIsNavJumpFloorUsd6() public view {
        bytes32 timeout = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.TransferTimeoutSeconds,
            600
        );
        (HyperCoreSubstrateLib.ConfigKey key, uint240 value) = _substrate.decodeConfig(timeout);
        assertEq(uint8(key), 7);
        assertEq(uint256(value), 600);

        bytes32 allowance = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.ActivationFeeAllowanceUsdcWei,
            1e8
        );
        (key, value) = _substrate.decodeConfig(allowance);
        assertEq(uint8(key), 8);
        assertEq(uint256(value), 1e8);

        bytes32 navJump = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxNavJumpBps, 5000);
        (key, value) = _substrate.decodeConfig(navJump);
        assertEq(uint8(key), 9);
        assertEq(uint256(value), 5000);

        bytes32 floorWord = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6, 1e6);
        (key, value) = _substrate.decodeConfig(floorWord);
        assertEq(uint8(key), 11);
        assertEq(uint256(value), 1e6);
    }
}
