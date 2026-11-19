// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @notice IL-9691: optional `Config{NavZeroBaselineCapUsd6}` (key 12) caps the first live Core value that the NAV jump
///         check accepts while the stored market value is zero. The value is validated on every check, compared only
///         while the stored value is zero. The cap must be non-zero and not below `NavJumpFloorUsd6` (Pete D-019).
contract HyperCoreNavZeroBaselineCapTest is HyperCoreEffectSettlementBase {
    /// @dev Config key 12 as a literal and the new error by signature (most tests need no new symbol). The file as a whole
    ///      does not compile on the base copy: `testEncodeDecodeConfigKey12RoundTrips` uses the new `ConfigKey` enum member.
    uint256 internal constant CAP_KEY = 12;

    function _capError(uint256 liveWad_, uint256 capWad_) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("HyperCoreNavZeroBaselineCapExceeded(uint256,uint256)", liveWad_, capWad_);
    }

    function _capWord(uint240 capUsd6_) internal pure returns (bytes32) {
        return bytes32((uint256(5) << 248) | (CAP_KEY << 240) | uint256(capUsd6_));
    }

    // ------------------------------------------------------------------
    // zero stored value: the cap is compared with the live value
    // ------------------------------------------------------------------
    function testLiveAboveCapWithZeroStoredRevertsRefresh() public {
        _grantFixture(true, 20e6);
        _fundCoreWithoutBooking(50e6);
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 0, "stored value is zero");

        vm.prank(_atomist);
        vm.expectRevert(_capError(50e18, 20e18));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testLiveAtCapWithZeroStoredPasses() public {
        _grantFixture(true, 50e6);
        _fundCoreWithoutBooking(50e6);
        uint256 nav = _refreshAndTotalAssets();
        assertGt(nav, 0, "booked");
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 50e6, 2e6, "live value booked");
    }

    function testMissingKeyKeepsUncappedFirstBooking() public {
        _fundCoreWithoutBooking(50e6);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 50e6, 2e6, "no key, no cap");
    }

    function testActionFuseEnforcesCapWithZeroStored() public {
        _grantFixture(true, 20e6);
        _fundCoreWithoutBooking(50e6);

        vm.expectRevert(_capError(50e18, 20e18));
        _vault.execute(_depositAction(1e6));
    }

    function testActivationThroughDepositFuseWithSmallCapPasses() public {
        _grantFixture(true, 20e6);
        _vault.execute(_depositAction(10e6));
        _settle(2);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 10e6, 2e6, "activated under the cap");
    }

    // ------------------------------------------------------------------
    // explicit 0 versus a missing key
    // ------------------------------------------------------------------
    function testExplicitZeroCapRevertsEvenWhenLiveIsZero() public {
        _grantFixture(true, 0);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, 0));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testExplicitZeroCapRevertsOnPositiveLive() public {
        _grantFixture(true, 0);
        _fundCoreWithoutBooking(1e6);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, 0));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // D-019: the cap must not be below NavJumpFloorUsd6
    // ------------------------------------------------------------------
    function testCapBelowFloorReverts() public {
        _grantFixtureWithFloor(true, 4e6, true, 5e6);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, 4e6));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testCapEqualToFloorIsAccepted() public {
        _grantFixtureWithFloor(true, 5e6, true, 5e6);
        _fundCoreWithoutBooking(5e6);
        _refreshAndTotalAssets();
        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "booked at cap == floor");
    }

    function testCapAboveFloorIsAccepted() public {
        _grantFixtureWithFloor(true, 6e6, true, 5e6);
        _refreshAndTotalAssets();
    }

    /// @dev The floor is required by the NAV jump check itself (IL-9597): without it the check reverts before the cap
    ///      is looked at, so the "floor not configured" cap rule reduces to the zero check, which is covered above.
    function testNoFloorRevertsFloorNotConfiguredRegardlessOfCap() public {
        _grantFixtureWithFloor(true, 1e6, false, 0);
        vm.prank(_atomist);
        vm.expectRevert(HyperCoreValuationLib.HyperCoreNavJumpFloorNotConfigured.selector);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testExplicitZeroFloorAcceptsPositiveCapAndRejectsZeroCap() public {
        _grantFixtureWithFloor(true, 1, true, 0);
        _refreshAndTotalAssets();
        _grantFixtureWithFloor(true, 0, true, 0);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, 0));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // fix #8: activation above the cap, user flow through the hook, encodeConfig key 12
    // ------------------------------------------------------------------
    function testActivationDepositAboveCapRevertsWithZeroStored() public {
        _grantFixture(true, 20e6);
        _fundCoreWithoutBooking(30e6);
        // stored is zero and the live Core value (30e6) already exceeds the cap: the deposit fuse reads it first
        vm.expectRevert(_capError(30e18, 20e18));
        _vault.execute(_depositAction(25e6));
    }

    /// @dev Pins the real behaviour (fix #8): an activation deposit above the cap is NOT blocked. The Core value read
    ///      before the transfer is 0, and the pending path books the amount as the stored value, so the cap (compared
    ///      only while the stored value is zero) never sees it. The cap only guards an unbooked donation.
    function testActivationDepositAboveCapIsBookedByPendingPath() public {
        _grantFixture(true, 20e6);
        _vault.execute(_depositAction(30e6));
        _settle(2);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 30e6, 2e6, "activation above the cap is booked");
    }

    function testUserDepositThroughCapitalFlowHookHitsCap() public {
        _grantFixture(true, 20e6);
        _fundCoreWithoutBooking(50e6);
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 0, "stored value is zero");

        vm.prank(_user);
        vm.expectRevert(_capError(50e18, 20e18));
        _vault.deposit(1e6, _user);
    }

    function testEncodeDecodeConfigKey12RoundTrips() public {
        bytes32 word = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavZeroBaselineCapUsd6, 7e6);
        assertEq(word, _capWord(7e6), "matches the literal layout");
        (HyperCoreSubstrateLib.ConfigKey key, uint240 value) = this.decodeExternal(word);
        assertEq(uint8(key), 12, "key 12");
        assertEq(uint256(value), 7e6, "value");
    }

    function decodeExternal(bytes32 w_) external pure returns (HyperCoreSubstrateLib.ConfigKey, uint240) {
        return HyperCoreSubstrateLib.decodeConfig(w_);
    }

    function testMissingKeyDoesNotCapPositiveLive() public {
        _fundCoreWithoutBooking(1e6);
        _refreshAndTotalAssets();
        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "booked without a cap");
    }

    // ------------------------------------------------------------------
    // non-zero stored value: the cap is not compared, only validated
    // ------------------------------------------------------------------
    function testNonZeroStoredIgnoresCapAboveLimitInsideJumpBand() public {
        _grantFixture(true, 5e6);
        _vault.execute(_depositAction(10e6));
        _settle(2);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 10e6, 2e6, "stored value present");

        _donate(3e6); // live ~13e6 exceeds the 5e6 cap but stays inside the 50% jump band
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 13e6, 2e6, "cap not applied to a non-zero base");
    }

    function testCapAboveUint64RevertsEvenWithNonZeroStored() public {
        _grantFixture(false, 0);
        _vault.execute(_depositAction(10e6));
        _settle(2);
        _refreshAndTotalAssets();
        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "stored value present");

        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantFixture(true, tooLarge);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, tooLarge));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testCapAtUint64MaxIsAccepted() public {
        _grantFixture(true, uint240(type(uint64).max));
        _fundCoreWithoutBooking(50e6);
        _refreshAndTotalAssets();
        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "booked");
    }

    function testCapAboveUint64RevertsWithZeroStored() public {
        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantFixture(true, tooLarge);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, tooLarge));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    /// @dev Gives the vault a Core account holding `usd6_` USDC that no refresh has booked yet.
    function _fundCoreWithoutBooking(uint256 usd6_) internal {
        CoreSimulatorLib.forceAccountActivation(address(_vault));
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, uint64(usd6_ * 100));
    }

    function _donate(uint256 usd6_) internal {
        uint64 current = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total;
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, current + uint64(usd6_ * 100));
    }

    function _depositAction(uint256 amount_) internal view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
            )
        );
    }

    /// @dev Re-grants the fixture substrate set for market 55 (explicit zero floor), with or without key 12.
    function _grantFixture(bool withCap_, uint240 capUsd6_) internal {
        _grantFixtureWithFloor(withCap_, capUsd6_, true, 0);
    }

    /// @dev Same as `_grantFixture` with a configurable `NavJumpFloorUsd6` (or none when `withFloor_` is false).
    function _grantFixtureWithFloor(bool withCap_, uint240 capUsd6_, bool withFloor_, uint240 floorUsd6_) internal {
        uint256 n = 8 + (withFloor_ ? 1 : 0) + (withCap_ ? 1 : 0);
        bytes32[] memory substrates = new bytes32[](n);
        substrates[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        substrates[1] = HyperCoreSubstrateLib.encodePerpMarket(HYPE_PERP, 1_000_000e6, false);
        substrates[2] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        substrates[3] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        substrates[4] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        substrates[5] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        substrates[6] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        substrates[7] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        uint256 i = 8;
        if (withFloor_) {
            substrates[i++] = HyperCoreSubstrateLib.encodeConfig(
                HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6,
                floorUsd6_
            );
        }
        if (withCap_) {
            substrates[i++] = _capWord(capUsd6_);
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
    }
}
