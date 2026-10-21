// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";

contract HyperCoreHip3SubstrateHarness {
    function grant(uint256 marketId_, bytes32[] memory substrates_) external {
        PlasmaVaultConfigLib.grantMarketSubstrates(marketId_, substrates_);
    }

    function bitmap(uint256 marketId_) external view returns (uint240) {
        return HyperCoreSubstrateLib.getPerpDexBitmap(marketId_);
    }

    function configured(uint256 marketId_, uint32 dex_) external view returns (bool) {
        return HyperCoreSubstrateLib.isPerpDexConfigured(marketId_, dex_);
    }

    function stats(uint256 marketId_) external view returns (uint256, bool, uint32) {
        return HyperCoreSubstrateLib.getPerpMarketStats(marketId_);
    }

    function config(uint240 value_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, value_);
    }

    function perp(uint32 asset_, uint88 cap_, bool reduceOnly_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodePerpMarket(asset_, cap_, reduceOnly_);
    }

    function spot(uint64 token_, address asset_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeSpotToken(token_, asset_);
    }

    function destination(address value_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeDestination(value_);
    }
}

contract HyperCoreHip3SubstrateTest is Test {
    uint256 private constant MARKET_ID = 55;
    uint256 private constant ALL_SUPPORTED = 1858;
    HyperCoreHip3SubstrateHarness private _harness;

    function setUp() public {
        _harness = new HyperCoreHip3SubstrateHarness();
        vm.chainId(999);
    }

    function testPerpDexBitmapDefaultsToNativeAndAcceptsSupportedMasks() public {
        assertEq(_harness.bitmap(MARKET_ID), 0);
        _grant(_config(0));
        assertEq(_harness.bitmap(MARKET_ID), 0);

        uint240[6] memory values = [uint240(2), 64, 256, 512, 1024, 1858];
        for (uint256 i; i < values.length; ++i) {
            _grant(_config(values[i]));
            assertEq(_harness.bitmap(MARKET_ID), values[i]);
        }
    }

    function testPerpDexBitmapRejectsEveryUnsupportedBitAndMixedMask() public {
        uint240[5] memory values = [uint240(1), 4, 128, uint240(1) << 239, 2 | 4];
        for (uint256 i; i < values.length; ++i) {
            _grant(_config(values[i]));
            vm.expectRevert(abi.encodeWithSelector(
                HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, values[i]
            ));
            _harness.bitmap(MARKET_ID);
        }
    }

    function testNonMainnetRejectsAnyNonzeroPerpDexBitmap() public {
        _grant(_config(2));
        vm.chainId(998);
        vm.expectRevert(abi.encodeWithSelector(
            HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, uint240(2)
        ));
        _harness.bitmap(MARKET_ID);
    }

    function testDuplicatePerpDexConfigUsesExistingDuplicateError() public {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _config(2);
        substrates[1] = _config(64);
        _harness.grant(MARKET_ID, substrates);
        vm.expectRevert(abi.encodeWithSelector(
            HyperCoreSubstrateLib.HyperCoreDuplicateConfig.selector,
            HyperCoreSubstrateLib.ConfigKey.PerpDexIds
        ));
        _harness.bitmap(MARKET_ID);
    }

    function testDexMembershipIncludesNativeAndOnlyConfiguredSupportedDexes() public {
        assertTrue(_harness.configured(MARKET_ID, 0));
        assertFalse(_harness.configured(MARKET_ID, 1));
        _grant(_config(2 | 1024));
        assertTrue(_harness.configured(MARKET_ID, 0));
        assertTrue(_harness.configured(MARKET_ID, 1));
        assertTrue(_harness.configured(MARKET_ID, 10));
        assertFalse(_harness.configured(MARKET_ID, 6));
        assertFalse(_harness.configured(MARKET_ID, 2));
        assertFalse(_harness.configured(MARKET_ID, 239));
        assertFalse(_harness.configured(MARKET_ID, 240));
        assertFalse(_harness.configured(MARKET_ID, type(uint32).max));
    }

    function testMembershipValidatesWholeBitmapForNativeAndOtherDexQueries() public {
        _grant(_config(2 | 4));
        vm.expectRevert(abi.encodeWithSelector(
            HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, uint240(6)
        ));
        _harness.configured(MARKET_ID, 0);

        _grant(_config(2 | 4));
        vm.expectRevert(abi.encodeWithSelector(
            HyperCoreSubstrateLib.HyperCoreUnsupportedPerpDexConfig.selector, uint240(6)
        ));
        _harness.configured(MARKET_ID, 1);
    }

    function testMarketStatsForNoGrantsAndNonPerpSubstrates() public {
        (uint256 count, bool hasHip3, uint32 soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 0);
        assertFalse(hasHip3);
        assertEq(soleAsset, 0);

        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _harness.spot(0, address(0x1234));
        substrates[1] = _harness.destination(address(0x5678));
        _harness.grant(MARKET_ID, substrates);
        (count, hasHip3, soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 0);
        assertFalse(hasHip3);
        assertEq(soleAsset, 0);
    }

    function testMarketStatsForSingleNativeAndHip3Grants() public {
        _grant(_harness.perp(42, 1_000_000, false));
        (uint256 count, bool hasHip3, uint32 soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 1);
        assertFalse(hasHip3);
        assertEq(soleAsset, 42);

        _grant(_harness.perp(110002, 1_000_000, false));
        (count, hasHip3, soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 1);
        assertTrue(hasHip3);
        assertEq(soleAsset, 110002);
    }

    function testMarketStatsCountEveryGrantIncludingDuplicateAssets() public {
        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = _harness.perp(42, 1_000_000, false);
        substrates[1] = _harness.perp(110002, 2_000_000, true);
        substrates[2] = _harness.perp(110002, 3_000_000, false);
        _harness.grant(MARKET_ID, substrates);
        (uint256 count, bool hasHip3, uint32 soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 3);
        assertTrue(hasHip3);
        assertEq(soleAsset, 0);
    }

    function testMarketStatsTwoNativeGrantsHaveNoSoleAsset() public {
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = _harness.perp(42, 1, false);
        substrates[1] = _harness.perp(43, 1, false);
        _harness.grant(MARKET_ID, substrates);
        (uint256 count, bool hasHip3, uint32 soleAsset) = _harness.stats(MARKET_ID);
        assertEq(count, 2);
        assertFalse(hasHip3);
        assertEq(soleAsset, 0);
    }

    function testExistingPerpAndConfigEncodingBytesStayFixed() public view {
        assertEq(
            _harness.perp(110002, 0x010203, true),
            bytes32(uint256(2) << 248 | uint256(110002) << 216 | uint256(0x010203) << 128 | uint256(1) << 120)
        );
        assertEq(_harness.config(1858), bytes32(uint256(5) << 248 | uint256(4) << 240 | 1858));
    }

    function _config(uint240 value_) private view returns (bytes32) {
        return _harness.config(value_);
    }

    function _grant(bytes32 substrate_) private {
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = substrate_;
        _harness.grant(MARKET_ID, substrates);
    }
}
