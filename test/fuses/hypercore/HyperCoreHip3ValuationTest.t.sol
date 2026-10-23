// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";
import {HyperCoreBalanceFuse} from "../../../contracts/fuses/hypercore/HyperCoreBalanceFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSupportedDexLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSupportedDexLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {HyperCoreTestHelper} from "./HyperCoreTestHelper.sol";
import {HyperCoreMockState} from "./mocks/MockHyperCorePrecompiles.sol";
import {MockPriceOracle} from "../aave_v4/MockPriceOracle.sol";
import {HyperCoreHip3RawFixtures} from "./fixtures/HyperCoreHip3RawFixtures.sol";

/// @dev The balance fuse is delegatecalled by PlasmaVaultMock, so this helper writes the same
///      namespaced pending slot in that vault's storage context via its generic enter(bytes) path.
///      Copied from `HyperCoreBalanceFuseTest.t.sol` (owned by another task) under a different
///      contract name, per T3 instructions.
contract HyperCoreHip3PendingStateSetter {
    function enter(bytes calldata params) external {
        (bool active, uint256 cachedValue, uint8 actionClass) = abi.decode(params, (bool, uint256, uint8));

        HyperCorePendingLib.PendingAction storage pending = HyperCorePendingLib.get();
        if (!active) {
            delete pending.pendingUntil;
            delete pending.enqueuedL1Block;
            delete pending.enqueuedEvmBlock;
            delete pending.actionClass;
            delete pending.actionId;
            delete pending.payloadHash;
            delete pending.cachedValueWad;
            delete pending.actionNonce;
            return;
        }

        pending.pendingUntil = uint64(block.timestamp + 100);
        pending.enqueuedL1Block = 0;
        pending.enqueuedEvmBlock = uint64(block.number);
        pending.actionClass = actionClass;
        pending.actionId = 1;
        pending.payloadHash = bytes32(uint256(1));
        pending.cachedValueWad = cachedValue;
        pending.actionNonce = 1;
    }
}

contract HyperCoreHip3ValuationTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint64 private constant USDC_INDEX = 0;
    address private constant ACCOUNT_MARGIN_SUMMARY_PRECOMPILE = address(0x80F);

    // Config value 2 = bit 1 set = XYZ_PERP_DEX only.
    uint240 private constant CONFIG_XYZ_ONLY = 2;
    // Config value 1858 = bits 1,6,8,9,10 set = the full supported HIP-3 mask.
    uint240 private constant CONFIG_ALL_FIVE = 1858;

    HyperCoreMockState private core;
    MockPriceOracle private oracle;
    HyperCoreBalanceFuse private balanceFuse;
    HyperCoreHip3PendingStateSetter private pendingSetter;
    PlasmaVaultMock private vault;
    address private spotAsset;

    function setUp() public {
        core = HyperCoreTestHelper.etchPrecompiles(vm);
        oracle = new MockPriceOracle();
        balanceFuse = new HyperCoreBalanceFuse(MARKET_ID);
        pendingSetter = new HyperCoreHip3PendingStateSetter();
        vault = new PlasmaVaultMock(address(pendingSetter), address(balanceFuse));
        vault.setPriceOracleMiddleware(address(oracle));
        spotAsset = makeAddr("spotAsset");
        // IL-8923: perp equity is counted only with the SpotToken(0) grant and is priced with its oracle price.
        // Granting it at $1 keeps the USD expectations of the tests below unchanged; `_grantConfig` re-grants it.
        _grantSpotUsdcOnly();
        oracle.setAssetPriceWithDecimals(spotAsset, 1e8, 8);
    }

    // 1. No config, chain 999: only native value counts; forced HIP-3 failures are irrelevant
    //    because no HIP-3 dex is ever read.
    function testNoConfigOnMainnetOnlyNativeValueCountsAndHip3DexesAreNeverRead() public {
        vm.chainId(999);
        _activate();
        _setNativeValue(5_000_000); // $5
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 999_000_000); // ignored: no config grants it
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.XYZ_PERP_DEX, true);
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.ABCD_PERP_DEX, true);
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.PARA_PERP_DEX, true);
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.MKTS_PERP_DEX, true);
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.IO_PERP_DEX, true);

        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreSupportedDexLib.XYZ_PERP_DEX, address(vault)),
            0
        );
        assertEq(vault.balanceOf(), 5e18);
    }

    // 2. Config value 0 behaves exactly like no config.
    function testConfigValueZeroBehavesLikeNoConfig() public {
        vm.chainId(999);
        _activate();
        _grantConfig(0);
        _setNativeValue(5_000_000);
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 999_000_000);

        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreSupportedDexLib.XYZ_PERP_DEX, address(vault)),
            0
        );
        assertEq(vault.balanceOf(), 5e18);
    }

    // 3. Config 2 (xyz only): value = native + xyz; a forced failure on an un-configured dex
    //    (PARA, bit 8) never surfaces because it is not read.
    function testConfigTwoValuesNativePlusXyzOnly() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(1_000_000); // $1
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2
        _setDexValue(HyperCoreSupportedDexLib.PARA_PERP_DEX, 4_000_000); // ignored: bit 8 not set
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.PARA_PERP_DEX, true);

        assertEq(vault.balanceOf(), 3e18);
    }

    // 4. Config 1858 (all five HIP-3 dexes): value = native + the five dex equities, each with a
    //    different amount so a missing or duplicated dex changes the sum.
    function testConfigAllFiveDexesSumsEveryEquity() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_ALL_FIVE);
        _setNativeValue(1_000_000); // $1
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2
        _setDexValue(HyperCoreSupportedDexLib.ABCD_PERP_DEX, 3_000_000); // $3
        _setDexValue(HyperCoreSupportedDexLib.PARA_PERP_DEX, 4_000_000); // $4
        _setDexValue(HyperCoreSupportedDexLib.MKTS_PERP_DEX, 5_000_000); // $5
        _setDexValue(HyperCoreSupportedDexLib.IO_PERP_DEX, 6_000_000); // $6

        assertEq(vault.balanceOf(), 21e18);
    }

    // 5. Spot + native + xyz: granted USDC spot balance priced by the oracle plus both margin
    //    summaries.
    //    IL-8923: the expected total changed on purpose from 6e18 to 7.5e18. The perp legs are 3 USDC, now
    //    priced with the same USDC oracle price as the spot leg ($1.50 here), not as $3; 6e18 pinned the
    //    par-USDC valuation fixed by IL-8923.
    function testSpotPlusNativePlusXyzSumsExactWadTotal() public {
        vm.chainId(999);
        _activate();
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        substrates[1] = _configSubstrate(CONFIG_XYZ_ONLY);
        vault.grantMarketSubstrates(MARKET_ID, substrates);

        _setSpotBalance(2e8, 15e7); // $3.00 total (see HyperCoreBalanceFuseTest for the same numbers)
        oracle.setAssetPriceWithDecimals(spotAsset, 15e7, 8);
        _setNativeValue(1_000_000); // 1 USDC = $1.50
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // 2 USDC = $3.00

        assertEq(vault.balanceOf(), 7.5e18);
    }

    // 6. Negative xyz equity offsets the rest, but the total stays positive.
    function testNegativeXyzEquityOffsetsRestButTotalStaysPositive() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(10_000_000); // $10
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, -3_000_000); // -$3

        assertEq(vault.balanceOf(), 7e18);
    }

    // 7. Negative total reverts with the exact signed WAD amount.
    function testNegativeTotalRevertsWithExactSignedWadAmount() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(-5_000_000); // -$5
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, -3_000_000); // -$3

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNegativeBalance.selector, int256(-8e18))
        );
        vault.balanceOf();
    }

    // 8. A configured dex whose read fails propagates the existing typed precompile error.
    function testConfiguredDexReadFailurePropagatesTypedError() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        core.setAccountMarginSummaryFail(HyperCoreSupportedDexLib.XYZ_PERP_DEX, true);

        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, ACCOUNT_MARGIN_SUMMARY_PRECOMPILE)
        );
        vault.balanceOf();
    }

    // 9. On a non-mainnet chain id, with no config, dex 1 is never read and value is native only.
    function testNonMainnetChainWithNoConfigNeverReadsHip3Dexes() public {
        vm.chainId(998);
        _activate();
        _setNativeValue(4_000_000); // $4

        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreSupportedDexLib.XYZ_PERP_DEX, address(vault)),
            0
        );
        assertEq(vault.balanceOf(), 4e18);
    }

    // 10. An invalid bitmap reverts before the unactivated-account short-circuit, for a bit outside
    //     the supported mask, for bit 0, and on a chain where the whole mask is empty.
    function testInvalidBitmapRevertsBeforeUnactivatedReturn() public {
        // Account is never activated for any of these three sub-cases.
        vm.chainId(999);

        uint240 unsupportedBit7 = uint240(1) << 7;
        _grantConfig(unsupportedBit7);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, unsupportedBit7
            )
        );
        vault.balanceOf();

        uint240 bit0 = 1;
        _grantConfig(bit0);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, bit0)
        );
        vault.balanceOf();

        vm.chainId(998);
        uint240 valueTwoOffMainnet = 2;
        _grantConfig(valueTwoOffMainnet);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, valueTwoOffMainnet
            )
        );
        vault.balanceOf();
    }

    // 11. A valid config on an unactivated account returns 0 and performs no 0x80F read at all.
    function testValidConfigUnactivatedAccountReturnsZeroWithNoMarginRead() public {
        vm.chainId(999);
        _grantConfig(CONFIG_XYZ_ONLY);
        // Account is left unactivated (default false).

        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreLib.NATIVE_PERP_DEX, address(vault)),
            0
        );
        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreSupportedDexLib.XYZ_PERP_DEX, address(vault)),
            0
        );
        assertEq(vault.balanceOf(), 0);
    }

    // 12. Equity is independent of PerpMarket grants: granting and revoking a PerpMarket substrate
    //     never changes the HIP-3 equity contribution.
    function testEquityIsIndependentOfPerpMarketGrants() public {
        vm.chainId(999);
        _activate();
        _setNativeValue(0);
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2

        _grantConfig(CONFIG_XYZ_ONLY);
        assertEq(vault.balanceOf(), 2e18);

        // IL-8534: valuation reads the position of every granted market, so the market must exist on Core
        core.setPerpAssetInfo(
            10002,
            HyperCoreMockState.PerpAssetInfo({
                coin: "xyz:NVDA", marginTableId: 0, szDecimals: 3, maxLeverage: 10, onlyIsolated: false
            })
        );
        // IL-8923: the list keeps the SpotToken(0) grant, the pricing key of the perp equity.
        bytes32[] memory withPerpMarket = new bytes32[](3);
        withPerpMarket[0] = _configSubstrate(CONFIG_XYZ_ONLY);
        withPerpMarket[1] = HyperCoreSubstrateLib.encodePerpMarket(110002, 0, false);
        withPerpMarket[2] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        vault.grantMarketSubstrates(MARKET_ID, withPerpMarket);
        assertEq(vault.balanceOf(), 2e18);

        _grantConfig(CONFIG_XYZ_ONLY); // replaces the full substrate list, revoking the PerpMarket grant
        assertEq(vault.balanceOf(), 2e18);
    }

    // 13. Clearing the bit removes the equity: replacing the config by 0 drops the HIP-3 leg.
    function testClearingTheBitRemovesTheEquity() public {
        vm.chainId(999);
        _activate();
        _setNativeValue(1_000_000); // $1
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2

        _grantConfig(CONFIG_XYZ_ONLY);
        assertEq(vault.balanceOf(), 3e18);

        _grantConfig(0); // replaces the full substrate list with an empty PerpDexIds config
        assertEq(vault.balanceOf(), 1e18);
    }

    // 14. While a transfer is pending the cached value is returned, not the live value (including xyz).
    function testPendingReturnsCachedValue() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(0);
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 50_000_000); // $50 live

        _setPending(true, 9e18, 1);
        assertEq(vault.balanceOf(), 9e18);

        _setPending(false, 0, 0);
        assertEq(vault.balanceOf(), 50e18, "live value once nothing is pending");
    }

    // 15. Mainnet fixture arithmetic: the real xyz snapshot converts exactly, with no spot and a
    //     zero native leg.
    function testMainnetFixtureArithmeticConvertsExactly() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(0);
        core.setAccountMarginSummary(
            HyperCoreSupportedDexLib.XYZ_PERP_DEX,
            address(vault),
            HyperCoreMockState.AccountMarginSummary({
                accountValue: 9386090926,
                marginUsed: 8592359262,
                ntlPos: 159999504640,
                rawUsd: -150613413714
            })
        );

        assertEq(vault.balanceOf(), uint256(9386090926) * 1e12);
    }

    // 16a. Gas note (not an assertion of a fixed number): the gas cost of the FIRST balanceOf()
    //      call of a fresh test, for a native-only vault without any PerpDexIds config. Measured
    //      against the test mock; only useful for comparing the three gas-note configurations
    //      against each other, not as a mainnet gas figure.
    function testGasNoteNativeOnlyNoConfig() public {
        vm.chainId(999);
        _activate();
        _setNativeValue(1_000_000); // $1

        uint256 g = gasleft();
        uint256 result = vault.balanceOf();
        g = g - gasleft();
        emit log_named_uint("gasNativeOnlyNoConfig", g);

        assertEq(result, 1e18);
    }

    // 16b. Gas note (not an assertion of a fixed number): the gas cost of the FIRST balanceOf()
    //      call of a fresh test, for a vault configured with config 2 (xyz only). Measured against
    //      the test mock; only useful for comparing the three gas-note configurations against each
    //      other, not as a mainnet gas figure.
    function testGasNoteConfigXyzOnly() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        _setNativeValue(1_000_000); // $1
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2

        uint256 g = gasleft();
        uint256 result = vault.balanceOf();
        g = g - gasleft();
        emit log_named_uint("gasConfigXyzOnly", g);

        assertEq(result, 3e18);
    }

    // 16c. Gas note (not an assertion of a fixed number): the gas cost of the FIRST balanceOf()
    //      call of a fresh test, for a vault configured with config 1858 (all five HIP-3 dexes).
    //      Measured against the test mock; only useful for comparing the three gas-note
    //      configurations against each other, not as a mainnet gas figure.
    function testGasNoteConfigAllFive() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_ALL_FIVE);
        _setNativeValue(1_000_000); // $1
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // $2
        _setDexValue(HyperCoreSupportedDexLib.ABCD_PERP_DEX, 3_000_000); // $3
        _setDexValue(HyperCoreSupportedDexLib.PARA_PERP_DEX, 4_000_000); // $4
        _setDexValue(HyperCoreSupportedDexLib.MKTS_PERP_DEX, 5_000_000); // $5
        _setDexValue(HyperCoreSupportedDexLib.IO_PERP_DEX, 6_000_000); // $6

        uint256 g = gasleft();
        uint256 result = vault.balanceOf();
        g = g - gasleft();
        emit log_named_uint("gasConfigAllFive", g);

        assertEq(result, 21e18);
    }

    // 17. IL-8923 (C-002): native and every enabled HIP-3 dex equity are USDC amounts, summed and priced once with
    //     the USDC oracle price.
    function testEveryDexEquityIsPricedWithUsdcOraclePrice() public {
        vm.chainId(999);
        _activate();
        _grantConfig(CONFIG_XYZ_ONLY);
        oracle.setAssetPriceWithDecimals(spotAsset, 9e7, 8); // USDC at $0.90
        _setNativeValue(1_000_000); // 1 USDC
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // 2 USDC

        assertEq(vault.balanceOf(), 2.7e18, "3 USDC of perp equity at $0.90");
    }

    // 18. IL-8923 (C-002), Pete D-009: without the SpotToken(0) grant no dex equity is counted and nothing reverts;
    //     the configured dexes are still read, so a failed read would still revert.
    function testDexEquityWithoutUsdcGrantIsNotCounted() public {
        vm.chainId(999);
        _activate();
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = _configSubstrate(CONFIG_XYZ_ONLY); // replaces the setUp list: no SpotToken(0) grant
        vault.grantMarketSubstrates(MARKET_ID, substrates);
        _setNativeValue(1_000_000); // 1 USDC
        _setDexValue(HyperCoreSupportedDexLib.XYZ_PERP_DEX, 2_000_000); // 2 USDC

        vm.expectCall(
            ACCOUNT_MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(HyperCoreSupportedDexLib.XYZ_PERP_DEX, address(vault))
        );
        assertEq(vault.balanceOf(), 0, "no grant: dex equity not counted");
    }

    function _activate() private {
        core.setCoreUserExists(address(vault), true);
    }

    function _configSubstrate(uint240 bitmap) private pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, bitmap);
    }

    /// @dev `grantMarketSubstrates` replaces the whole list, so the config is granted together with the
    ///      SpotToken(0) grant that prices the perp equity (IL-8923).
    function _grantConfig(uint240 bitmap) private {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _configSubstrate(bitmap);
        substrates[1] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _grantSpotUsdcOnly() private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_INDEX, spotAsset);
        vault.grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _setSpotBalance(uint64 total, uint64 hold) private {
        core.setSpotBalance(
            address(vault),
            USDC_INDEX,
            HyperCoreMockState.SpotBalance({total: total, hold: hold, entryNtl: 0})
        );
    }

    function _setNativeValue(int64 accountValue) private {
        _setDexValue(HyperCoreLib.NATIVE_PERP_DEX, accountValue);
    }

    function _setDexValue(uint32 dex, int64 accountValue) private {
        core.setAccountMarginSummary(
            dex,
            address(vault),
            HyperCoreMockState.AccountMarginSummary({
                accountValue: accountValue,
                marginUsed: 0,
                ntlPos: 0,
                rawUsd: accountValue
            })
        );
    }

    function _setPending(bool active, uint256 cachedValue, uint8 actionClass) private {
        vault.enter(abi.encode(active, cachedValue, actionClass));
    }
}
