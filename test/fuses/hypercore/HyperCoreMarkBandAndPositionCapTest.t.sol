// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {HyperCoreDepositFuse, HyperCoreDepositFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreOrderFuse, HyperCoreOrderFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByCloidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";

/// @dev External wrapper so reverts of the pure substrate codecs can be asserted.
contract PositionCapCodecHarness {
    function encode(uint32 asset_, uint88 cap_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodePerpPositionCap(asset_, cap_);
    }

    function decode(bytes32 word_) external pure returns (uint32, uint88) {
        return HyperCoreSubstrateLib.decodePerpPositionCap(word_);
    }

    function substrateType(bytes32 word_) external pure returns (HyperCoreSubstrateLib.SubstrateType) {
        return HyperCoreSubstrateLib.substrateType(word_);
    }

    function encodeConfig(HyperCoreSubstrateLib.ConfigKey key_, uint240 value_) external pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeConfig(key_, value_);
    }
}

/// @notice IL-8534: mark-vs-Core-oracle valuation band and aggregate per-market position cap, on a FusionFactory vault
///         and the offline Core simulator (HIP-3 reads are served by the simulator plus a 0x813 mock).
contract HyperCoreMarkBandAndPositionCapTest is HyperCoreEffectSettlementBase {
    uint256 internal constant ATTACK = 500_000e6;
    uint32 internal constant NVDA_ACTION_ASSET = 110_002;
    uint32 internal constant NVDA_READ_INDEX = 10_002;
    address internal constant POSITION2 = address(0x813);
    address internal constant ORACLE_PX = address(0x807);

    address internal _attacker = makeAddr("ATTACKER");
    PositionCapCodecHarness internal _codec;

    function setUp() public override {
        super.setUp();
        _codec = new PositionCapCodecHarness();
        vm.prank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _attacker, 0);
        _usdc.mint(_attacker, ATTACK);
        vm.prank(_attacker);
        _usdc.approve(address(_vault), ATTACK);
    }

    // ------------------------------------------------------------------
    // codecs
    // ------------------------------------------------------------------
    function testPositionCapCodecRoundTripAndTypeFlag() public view {
        bytes32 word = _codec.encode(NVDA_ACTION_ASSET, 123_456e6);
        (uint32 asset, uint88 cap) = _codec.decode(word);
        assertEq(asset, NVDA_ACTION_ASSET);
        assertEq(cap, 123_456e6);
        assertEq(uint8(_codec.substrateType(word)), uint8(HyperCoreSubstrateLib.SubstrateType.PerpPositionCap));
        assertEq(uint8(HyperCoreSubstrateLib.SubstrateType.PerpPositionCap), 7, "appended after SendCap");
        assertEq(uint8(HyperCoreSubstrateLib.ConfigKey.MaxMarkOracleDeviationBps), 10, "appended after MaxNavJumpBps");
    }

    function testPositionCapCodecRejectsDirtyLowBitsAndWrongType() public {
        bytes32 word = _codec.encode(150, 1e6);
        bytes32 dirty = bytes32(uint256(word) | 1);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidSubstrate.selector, dirty));
        _codec.decode(dirty);

        bytes32 wrongType = HyperCoreSubstrateLib.encodePerpMarket(150, 1e6, false);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidSubstrate.selector, wrongType));
        _codec.decode(wrongType);

        assertEq(uint8(_codec.substrateType(bytes32(uint256(8) << 248))), 0, "type above the last is Undefined");
    }

    function testConfigKeyBoundMovedToMarkOracleBand() public {
        _codec.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxMarkOracleDeviationBps, 500);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidConfigKey.selector, uint8(0)));
        _codec.encodeConfig(HyperCoreSubstrateLib.ConfigKey.Undefined, 1);
    }

    // ------------------------------------------------------------------
    // Part 1: band
    // ------------------------------------------------------------------
    function testPoC_MarkPlus20PercentRevertsInsteadOfPayingTheAttacker() public {
        _openLong(1000e8);

        vm.prank(_attacker);
        uint256 shares = _vault.deposit(ATTACK, _attacker); // fair entry, mark == oracle

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000); // +20% pushed mark, oracle stays 400_000
        bytes memory err = _deviationError(HYPE_PERP, 480_000, 400_000);

        vm.prank(_attacker);
        vm.expectRevert(err);
        _vault.redeem(shares, _attacker, _attacker);

        vm.prank(_attacker);
        vm.expectRevert(err);
        _vault.deposit(1e6, _attacker);

        // the refresh is not a user flow: it passes while the band blocks share-priced flows
        vm.prank(_atomist);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));

        // the mark returns: the attacker exits at fair value, no profit
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);
        vm.prank(_attacker);
        uint256 got = _vault.redeem(shares, _attacker, _attacker);
        assertLe(got, ATTACK, "no gain from the pushed mark");
    }

    function testMarkInsideAndOutsideDefaultBand() public {
        _openLong(1000e8);

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 416_000); // +4%
        _depositPasses();

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 420_000); // +5% exactly, inside (strict >)
        _depositPasses();

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 420_001);
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 420_001, 400_000));
        _vault.deposit(1e6, _attacker);

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 376_000); // -6%
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 376_000, 400_000));
        _vault.deposit(1e6, _attacker);

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 380_000); // -5% exactly
        _depositPasses();
    }

    function testBandConfigZeroAndAboveUint64Revert() public {
        _openLong(1000e8);
        _grantWith(_one(_band(0)));
        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreMarkOracleBandConfigInvalid.selector, uint240(0)));
        _vault.deposit(1e6, _attacker);

        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantWith(_one(_band(tooLarge)));
        vm.prank(_attacker);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreMarkOracleBandConfigInvalid.selector, tooLarge)
        );
        _vault.deposit(1e6, _attacker);
    }

    function testCustomBandOf1000LetsPlus8PercentPass() public {
        _openLong(1000e8);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 432_000); // +8%
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 432_000, 400_000));
        _vault.deposit(1e6, _attacker);

        _grantWith(_one(_band(1000)));
        _depositPasses();

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 450_000); // +12.5% still outside the widened band
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 450_000, 400_000));
        _vault.deposit(1e6, _attacker);
    }

    function testZeroOraclePriceRevertsWithHeldPosition() public {
        _openLong(1000e8);
        vm.mockCall(ORACLE_PX, abi.encode(HYPE_PERP), abi.encode(uint64(0)));
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 400_000, 0));
        _vault.deposit(1e6, _attacker);
        vm.clearMockedCalls();
    }

    function testMarketWithoutPositionIsIgnoredEvenIfMarkAndOracleDiverge() public {
        _activateAndFundPerp();
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 900_000);
        CoreSimulatorLib.setOraclePx(HYPE_PERP, 400_000);
        _depositPasses();

        vm.mockCall(ORACLE_PX, abi.encode(HYPE_PERP), abi.encode(uint64(0)));
        _depositPasses(); // not even the oracle is read without a position
        vm.clearMockedCalls();
    }

    function testUnactivatedAccountShortCircuitsBeforeTheBand() public {
        // no Core account yet: valuation returns 0 without reading anything, even with an invalid band config
        _grantWith(_one(_band(0)));
        _depositPasses();
    }

    function testRevokedMarketGrantStopsBeingChecked() public {
        _openLong(1000e8);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000);
        // re-grant without the HYPE PerpMarket: nothing is enumerated any more
        bytes32[] memory subs = new bytes32[](2);
        subs[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        subs[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, subs);
        _depositPasses();
    }

    // ---- HIP-3 -------------------------------------------------------
    function testHip3BandUsesTheReadIndexAndDetectsDivergence() public {
        _setupHip3Market(5000); // 5.000 NVDA long
        // aligned at the read index; the ACTION asset id (110002) diverges, which would be read by mistake
        CoreSimulatorLib.setMarkPx(NVDA_READ_INDEX, 100_000);
        CoreSimulatorLib.setOraclePx(NVDA_READ_INDEX, 100_000);
        CoreSimulatorLib.setMarkPx(NVDA_ACTION_ASSET, 480_000);
        CoreSimulatorLib.setOraclePx(NVDA_ACTION_ASSET, 100_000);
        _depositPasses();

        // diverge at the read index: detected, reported with the action asset
        CoreSimulatorLib.setMarkPx(NVDA_READ_INDEX, 120_000);
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(NVDA_ACTION_ASSET, 120_000, 100_000));
        _vault.deposit(1e6, _attacker);

        // inside the band again
        CoreSimulatorLib.setMarkPx(NVDA_READ_INDEX, 104_000);
        _depositPasses();
    }

    function testHip3MarketOfADisabledDexIsNotRead() public {
        _setupHip3Market(5000);
        CoreSimulatorLib.setMarkPx(NVDA_READ_INDEX, 150_000);
        CoreSimulatorLib.setOraclePx(NVDA_READ_INDEX, 100_000);
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(NVDA_ACTION_ASSET, 150_000, 100_000));
        _vault.deposit(1e6, _attacker);

        // same PerpMarket grant, dex bit cleared: NAV does not value the dex, so the market is not checked
        bytes32[] memory extra = new bytes32[](1);
        extra[0] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, 0);
        _grantHip3(extra);
        _depositPasses();
    }

    // The band guards share-priced flows only (capital-flow pre-hook). TIMING orders/cancels, execute and
    // refreshes are not gated, so the manager can de-risk while mark and oracle diverge.
    // ------------------------------------------------------------------
    function testManagerDeRisksWhileMarkDivergesAndUserFlowsStayBlocked() public {
        _openLong(1000e8);
        vm.prank(_attacker);
        uint256 shares = _vault.deposit(10_000e6, _attacker);

        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000); // +20%, beyond the 5% band
        bytes memory err = _deviationError(HYPE_PERP, 480_000, 400_000);

        // refresh passes
        _refreshAndTotalAssets();

        // user flows revert
        vm.prank(_attacker);
        vm.expectRevert(err);
        _vault.deposit(1e6, _attacker);
        vm.prank(_attacker);
        vm.expectRevert(err);
        _vault.redeem(shares, _attacker, _attacker);

        // TIMING order, cancel and a reduce-only close all pass through execute
        _executeOrder(true, 30e8, 10e8, false, HyperCoreLib.TIF_GTC, CLOID_2);
        _settle(10);
        _executeCancelByCloid(CLOID_2);
        _settle(10);
        _executeOrder(false, 35e8, 1000e8, true, HyperCoreLib.TIF_IOC, CLOID_3);
        _settle(10);
        assertEq(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 0, "position closed");

        // still diverged but flat: nothing is held, so user flows pass; and after convergence too
        _depositPasses();
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);
        vm.prank(_attacker);
        assertGt(_vault.redeem(shares, _attacker, _attacker), 0);
    }

    function testUserFlowsPassAfterConvergence() public {
        _openLong(1000e8);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000);
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 480_000, 400_000));
        _vault.deposit(1e6, _attacker);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 410_000);
        _depositPasses();
    }

    function testOrderIsNotBlockedByTheBandButUsersAre() public {
        _openLong(1000e8);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000);
        // orders do no valuation (TIMING-only), so they are not subject to the band
        _executeOrder(false, 35e8, 100e8, true, HyperCoreLib.TIF_IOC, CLOID_3);
        // users stay blocked by the band once the order's Core block has passed (the mini-gate is checked first)
        CoreSimulatorLib.nextBlock();
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 480_000, 400_000));
        _vault.deposit(1e6, _attacker);
    }

    // ------------------------------------------------------------------
    // Part 2: aggregate position cap
    // ------------------------------------------------------------------
    function testIncreaseBeyondCapRevertsAndWithinCapPasses() public {
        _openLong(1000e8); // 1000 HYPE
        _grantWith(_one(_cap(HYPE_PERP, 50_000e6)));

        // 1200 HYPE at 45 = 54,000 > 50,000
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePositionCapExceeded.selector, HYPE_PERP, 54_000e6, 50_000e6));
        _executeOrder(true, 45e8, 200e8, false, HyperCoreLib.TIF_IOC, CLOID_2);

        // 1100 HYPE at 45 = 49,500 <= 50,000
        _executeOrder(true, 45e8, 100e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
        _settle(10);
        assertEq(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 110_000, "szi in 0.01 HYPE units");
    }

    function testReducingOrderPassesEvenWhenAboveTheCap() public {
        _openLong(1000e8);
        _grantWith(_one(_cap(HYPE_PERP, 20_000e6))); // 1000 HYPE is above it

        // an increase is refused
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePositionCapExceeded.selector, HYPE_PERP, 45_450e6, 20_000e6));
        _executeOrder(true, 45e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);

        // a reduce is allowed (still above the cap afterwards)
        _executeOrder(false, 35e8, 100e8, true, HyperCoreLib.TIF_IOC, CLOID_2);
        _settle(10);
        assertEq(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 90_000);
    }

    function testFlipBeyondCapRevertsButFlipThatShrinksAbsSizePasses() public {
        _openLong(1000e8);
        _grantWith(_one(_cap(HYPE_PERP, 50_000e6)));

        // sell 3000: long 1000 -> short 2000, |size| grows; sell admitted at max(35, mark 40) = 40 -> 80,000
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePositionCapExceeded.selector, HYPE_PERP, 80_000e6, 50_000e6));
        _executeOrder(false, 35e8, 3000e8, false, HyperCoreLib.TIF_IOC, CLOID_2);

        // sell 1500: long 1000 -> short 500, |size| shrinks: allowed
        _executeOrder(false, 35e8, 1500e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
        _settle(10);
        assertEq(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, -50_000);

        // from short 500, a further sell that grows |size| to 1500 is within the 50k cap at 40 (60k)? no: refused
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePositionCapExceeded.selector, HYPE_PERP, 60_000e6, 50_000e6));
        _executeOrder(false, 35e8, 1000e8, false, HyperCoreLib.TIF_IOC, CLOID_3);
    }

    function testNoCapGrantedOnlyThePerOrderCapApplies() public {
        _openLong(1000e8);
        // 2000 more HYPE at 45 = 90,000: far above any aggregate cap we could have set, passes the 1M per-order cap
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        _executeOrder(true, 45e8, 2000e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
        _settle(10);
        assertEq(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 300_000);
    }

    function testDuplicateCapGrantIsRejected() public {
        _openLong(1000e8);
        bytes32[] memory extra = new bytes32[](2);
        extra[0] = _cap(HYPE_PERP, 50_000e6);
        extra[1] = _cap(HYPE_PERP, 60_000e6);
        _grantWith(extra);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidSubstrate.selector, extra[1]));
        _executeOrder(true, 45e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
    }

    function testHip3AssetCapUsesReadIndexPosition() public {
        _setupHip3Market(5000); // 5.000 NVDA at mark/oracle 100 (raw 100_000, szDecimals 3)
        CoreSimulatorLib.setMarkPx(NVDA_READ_INDEX, 100_000);
        CoreSimulatorLib.setOraclePx(NVDA_READ_INDEX, 100_000);
        bytes32[] memory extra = new bytes32[](2);
        extra[0] = _cap(NVDA_ACTION_ASSET, 1_000e6);
        extra[1] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, 2);
        _grantHip3(extra);

        // post-order 5 + 10 = 15 NVDA at limit 100 = 1,500 > 1,000
        vm.expectRevert(abi.encodeWithSelector(HyperCoreOrderFuse.HyperCoreOrderFusePositionCapExceeded.selector, NVDA_ACTION_ASSET, 1_500e6, 1_000e6));
        _executeOrderAsset(NVDA_ACTION_ASSET, true, 100e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);

        // 5 + 1 = 6 NVDA = 600 <= 1,000: the cap check passes (the order itself is accepted by the mock chain)
        vm.expectEmit(false, false, false, false, address(_vault));
        emit HyperCoreOrderFuse.HyperCoreOrderFuseEnter(address(0), 0, false, 0, 0, false, 0, 0);
        _executeOrderAsset(NVDA_ACTION_ASSET, true, 100e8, 1e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _depositPasses() internal {
        vm.prank(_attacker);
        assertGt(_vault.deposit(1e6, _attacker), 0);
    }

    function _deviationError(uint32 asset_, uint64 mark_, uint64 oracle_) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreMarkOracleDeviation.selector, asset_, mark_, oracle_);
    }

    function _band(uint240 bps_) internal pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxMarkOracleDeviationBps, bps_);
    }

    function _cap(uint32 asset_, uint88 capUsd6_) internal pure returns (bytes32) {
        return HyperCoreSubstrateLib.encodePerpPositionCap(asset_, capUsd6_);
    }

    function _one(bytes32 word_) internal pure returns (bytes32[] memory out) {
        out = new bytes32[](1);
        out[0] = word_;
    }

    /// @dev Funds Core (spot then perp margin) so the account is active; no position yet.
    function _activateAndFundPerp() internal {
        _execute(address(_depositFuse), abi.encodeWithSelector(
            HyperCoreDepositFuse.enter.selector, HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 100_000e6})
        ));
        _settle(2);
        _refreshAndTotalAssets();
        _execute(address(_marginFuse), abi.encodeWithSelector(
            HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
        ));
        _settle(2);
        _refreshAndTotalAssets();
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 1);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000); // $40
        CoreSimulatorLib.setOraclePx(HYPE_PERP, 400_000); // pinned: the oracle no longer follows the mark
    }

    /// @dev Opens a long of `sz1e8_` HYPE at ~$40 (TIMING) and settles it.
    function _openLong(uint64 sz1e8_) internal {
        _activateAndFundPerp();
        _executeOrder(true, 45e8, sz1e8_, false, HyperCoreLib.TIF_IOC, CLOID_1);
        _settle(10);
        assertGt(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 0, "long opened");
        _refreshAndTotalAssets();
    }

    function _setupHip3Market(int64 szi_) internal {
        vm.chainId(999);
        _activateAndFundPerp();
        _hyperCore.registerPerpAssetInfo(
            NVDA_READ_INDEX,
            PrecompileLib.PerpAssetInfo({
                coin: "xyz:NVDA", marginTableId: 0, szDecimals: 3, maxLeverage: 10, onlyIsolated: false
            })
        );
        vm.mockCall(
            POSITION2,
            abi.encode(address(_vault), NVDA_READ_INDEX),
            abi.encode(szi_, uint64(0), int64(0), uint32(1), false)
        );
        // the action asset id is NOT a valid read index: any read there would see no position (and zero prices)
        bytes32[] memory extra = new bytes32[](1);
        extra[0] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.PerpDexIds, 2);
        _grantHip3(extra);
    }

    /// @dev Full fixture substrate list plus `extra_`.
    function _grantWith(bytes32[] memory extra_) internal {
        bytes32[] memory subs = new bytes32[](8 + extra_.length);
        subs[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        subs[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        _fillCommon(subs);
        for (uint256 i; i < extra_.length; ++i) subs[8 + i] = extra_[i];
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, subs);
    }

    /// @dev HIP-3 grants require a single PerpMarket: NVDA replaces HYPE.
    function _grantHip3(bytes32[] memory extra_) internal {
        bytes32[] memory subs = new bytes32[](8 + extra_.length);
        subs[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        subs[1] = HyperCoreSubstrateLib.encodePerpMarket(NVDA_ACTION_ASSET, 1_000_000e6, false);
        _fillCommon(subs);
        for (uint256 i; i < extra_.length; ++i) subs[8 + i] = extra_[i];
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, subs);
    }

    function _fillCommon(bytes32[] memory subs_) private view {
        subs_[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        subs_[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        subs_[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        subs_[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        subs_[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        subs_[7] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6, 1_000_000e6
        );
    }

    function _execute(address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        _vault.execute(actions);
    }

    function _executeOrder(bool isBuy_, uint64 limitPx_, uint64 sz_, bool reduceOnly_, uint8 tif_, uint128 cloid_)
        internal
    {
        _executeOrderAsset(HYPE_PERP, isBuy_, limitPx_, sz_, reduceOnly_, tif_, cloid_);
    }

    function _executeOrderAsset(
        uint32 asset_,
        bool isBuy_,
        uint64 limitPx_,
        uint64 sz_,
        bool reduceOnly_,
        uint8 tif_,
        uint128 cloid_
    ) internal {
        _execute(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: asset_,
                    isBuy: isBuy_,
                    limitPx: limitPx_,
                    sz: sz_,
                    reduceOnly: reduceOnly_,
                    tif: tif_,
                    cloid: cloid_
                })
            )
        );
    }

    function _executeCancelByCloid(uint128 cloid_) internal {
        _execute(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByCloid.selector,
                HyperCoreCancelFuseCancelByCloidData({asset: HYPE_PERP, cloid: cloid_})
            )
        );
    }
}
