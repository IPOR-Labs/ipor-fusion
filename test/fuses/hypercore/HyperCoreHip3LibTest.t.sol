// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreAssetIdLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreAssetIdLib.sol";
import {HyperCoreSupportedDexLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSupportedDexLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";

contract HyperCoreHip3LibHarness {
    function isNativePerpAsset(uint32 asset_) external pure returns (bool) {
        return HyperCoreAssetIdLib.isNativePerpAsset(asset_);
    }

    function isHip3Asset(uint32 asset_) external pure returns (bool) {
        return HyperCoreAssetIdLib.isHip3Asset(asset_);
    }

    function perpDexOf(uint32 asset_) external pure returns (uint32) {
        return HyperCoreAssetIdLib.perpDexOf(asset_);
    }

    function readIndexOf(uint32 asset_) external pure returns (uint32) {
        return HyperCoreAssetIdLib.readIndexOf(asset_);
    }

    function supportedHip3DexMask() external view returns (uint256) {
        return HyperCoreSupportedDexLib.supportedHip3DexMask();
    }

    function isSupportedPerpDex(uint32 dex_) external view returns (bool) {
        return HyperCoreSupportedDexLib.isSupportedPerpDex(dex_);
    }

    function position2(address user_, uint32 readIndex_) external view returns (HyperCoreLib.Position memory) {
        return HyperCoreLib.position2(user_, readIndex_);
    }

    function position(address user_, uint32 asset_) external view returns (HyperCoreLib.Position memory) {
        return HyperCoreLib.position(user_, asset_);
    }
}

contract HyperCoreHip3LibTest is Test {
    HyperCoreHip3LibHarness private _lib;

    function setUp() public {
        _lib = new HyperCoreHip3LibHarness();
    }

    function testIsNativePerpAsset() public view {
        assertTrue(_lib.isNativePerpAsset(0));
        assertTrue(_lib.isNativePerpAsset(9999));
        assertFalse(_lib.isNativePerpAsset(10000));
    }

    function testIsHip3Asset() public view {
        assertTrue(_lib.isHip3Asset(110000));
        assertTrue(_lib.isHip3Asset(110002));
        assertTrue(_lib.isHip3Asset(110107));
        assertTrue(_lib.isHip3Asset(180000));
        assertTrue(_lib.isHip3Asset(190005));
        assertTrue(_lib.isHip3Asset(200001));
        assertTrue(_lib.isHip3Asset(99999999));

        assertFalse(_lib.isHip3Asset(0));
        assertFalse(_lib.isHip3Asset(9999));
        assertFalse(_lib.isHip3Asset(10000));
        assertFalse(_lib.isHip3Asset(99999));
        assertFalse(_lib.isHip3Asset(100000));
        assertFalse(_lib.isHip3Asset(109999));
        assertFalse(_lib.isHip3Asset(100000000));
        assertFalse(_lib.isHip3Asset(type(uint32).max));
    }

    function testPerpDexOfAndReadIndexOf() public view {
        _assertDexAndIndex(0, 0, 0);
        _assertDexAndIndex(9999, 0, 9999);
        _assertDexAndIndex(110000, 1, 10000);
        _assertDexAndIndex(110002, 1, 10002);
        _assertDexAndIndex(110107, 1, 10107);
        _assertDexAndIndex(160000, 6, 60000);
        _assertDexAndIndex(180000, 8, 80000);
        _assertDexAndIndex(190005, 9, 90005);
        _assertDexAndIndex(200001, 10, 100001);
    }

    function _assertDexAndIndex(uint32 asset_, uint32 expectedDex_, uint32 expectedIndex_) private view {
        assertEq(_lib.perpDexOf(asset_), expectedDex_);
        assertEq(_lib.readIndexOf(asset_), expectedIndex_);
    }

    function testPerpDexOfRevertsOnInvalidAsset() public {
        uint32[6] memory invalidAssets =
            [uint32(10000), uint32(99999), uint32(100000), uint32(109999), uint32(100000000), type(uint32).max];
        for (uint256 i = 0; i < invalidAssets.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, invalidAssets[i]));
            _lib.perpDexOf(invalidAssets[i]);
        }
    }

    function testReadIndexOfRevertsOnInvalidAsset() public {
        uint32[6] memory invalidAssets =
            [uint32(10000), uint32(99999), uint32(100000), uint32(109999), uint32(100000000), type(uint32).max];
        for (uint256 i = 0; i < invalidAssets.length; i++) {
            vm.expectRevert(abi.encodeWithSelector(HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector, invalidAssets[i]));
            _lib.readIndexOf(invalidAssets[i]);
        }
    }

    function testSupportedHip3DexMask() public {
        vm.chainId(999);
        assertEq(_lib.supportedHip3DexMask(), 1858);

        vm.chainId(998);
        assertEq(_lib.supportedHip3DexMask(), 0);

        vm.chainId(31337);
        assertEq(_lib.supportedHip3DexMask(), 0);
    }

    function testIsSupportedPerpDexOnMainnet() public {
        vm.chainId(999);
        uint32[6] memory supported = [uint32(0), uint32(1), uint32(6), uint32(8), uint32(9), uint32(10)];
        for (uint256 i = 0; i < supported.length; i++) {
            assertTrue(_lib.isSupportedPerpDex(supported[i]));
        }

        uint32[11] memory unsupported = [
            uint32(2),
            uint32(3),
            uint32(4),
            uint32(5),
            uint32(7),
            uint32(11),
            uint32(239),
            uint32(240),
            uint32(255),
            uint32(256),
            type(uint32).max
        ];
        for (uint256 i = 0; i < unsupported.length; i++) {
            assertFalse(_lib.isSupportedPerpDex(unsupported[i]));
        }
    }

    function testIsSupportedPerpDexOnNonMainnetChain() public {
        vm.chainId(998);
        assertTrue(_lib.isSupportedPerpDex(0));
        assertFalse(_lib.isSupportedPerpDex(1));
        assertFalse(_lib.isSupportedPerpDex(6));
        assertFalse(_lib.isSupportedPerpDex(8));
        assertFalse(_lib.isSupportedPerpDex(9));
        assertFalse(_lib.isSupportedPerpDex(10));
    }

    function testFuzzHip3AssetRoundTrip(uint32 dex_, uint32 idx_) public view {
        uint32 dex = uint32(bound(uint256(dex_), 1, 9989));
        uint32 idx = uint32(bound(uint256(idx_), 0, 9999));
        uint32 asset = 100000 + dex * 10000 + idx;

        assertTrue(_lib.isHip3Asset(asset));
        assertEq(_lib.perpDexOf(asset), dex);
        assertEq(_lib.readIndexOf(asset), dex * 10000 + idx);
    }

    function testFuzzNativeAssetRoundTrip(uint32 asset_) public view {
        uint32 asset = uint32(bound(uint256(asset_), 0, 9999));

        assertEq(_lib.perpDexOf(asset), 0);
        assertEq(_lib.readIndexOf(asset), asset);
    }

    function testPositionAndPosition2ReadDifferentPrecompiles() public {
        address user = address(0xCAFE);
        uint32 readIndex = 80000;

        vm.mockCall(
            HyperCoreLib.POSITION_PRECOMPILE,
            abi.encode(user, readIndex),
            abi.encode(int64(1), uint64(2), int64(3), uint32(4), false)
        );
        vm.mockCall(
            HyperCoreLib.POSITION2_PRECOMPILE,
            abi.encode(user, readIndex),
            abi.encode(int64(-11), uint64(22), int64(-33), uint32(44), true)
        );

        vm.expectCall(address(0x813), abi.encode(user, readIndex));
        HyperCoreLib.Position memory fromPosition2 = _lib.position2(user, readIndex);
        HyperCoreLib.Position memory fromPosition = _lib.position(user, readIndex);

        assertEq(fromPosition.szi, 1);
        assertEq(fromPosition.entryNtl, 2);
        assertEq(fromPosition.isolatedRawUsd, 3);
        assertEq(fromPosition.leverage, 4);
        assertFalse(fromPosition.isIsolated);

        assertEq(fromPosition2.szi, -11);
        assertEq(fromPosition2.entryNtl, 22);
        assertEq(fromPosition2.isolatedRawUsd, -33);
        assertEq(fromPosition2.leverage, 44);
        assertTrue(fromPosition2.isIsolated);
    }

    function testPosition2RevertsOnPrecompileFailure() public {
        address user = address(0xCAFE);
        uint32 readIndex = 80000;

        vm.mockCallRevert(HyperCoreLib.POSITION2_PRECOMPILE, abi.encode(user, readIndex), bytes("failed"));
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, HyperCoreLib.POSITION2_PRECOMPILE)
        );
        _lib.position2(user, readIndex);
    }

    function testPosition2RevertsOnEmptyReturn() public {
        vm.etch(HyperCoreLib.POSITION2_PRECOMPILE, bytes(""));
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreLib.HyperCorePrecompileFailed.selector, HyperCoreLib.POSITION2_PRECOMPILE)
        );
        _lib.position2(address(0xCAFE), 80000);
    }

    function testPrecompileAddressesArePinned() public pure {
        assertEq(HyperCoreLib.POSITION_PRECOMPILE, address(0x800));
        assertEq(HyperCoreLib.POSITION2_PRECOMPILE, address(0x813));
    }

    function testPerpDexBitmapBitsIsPinned() public pure {
        assertEq(HyperCoreSubstrateLib.PERP_DEX_BITMAP_BITS, 240);
    }
}
