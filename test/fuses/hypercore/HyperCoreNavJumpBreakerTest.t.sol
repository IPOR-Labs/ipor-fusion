// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @notice IL-8533 NAV jump circuit breaker on a FusionFactory vault + offline Core simulator. Ports the
///         reviewer's precompile PoCs (empty reply, same-layout semantic change) and proves the breaker trips
///         on a repriced Core value but not on legitimate transfers.
contract HyperCoreNavJumpBreakerTest is HyperCoreEffectSettlementBase {
    address internal constant MARGIN_SUMMARY_PRECOMPILE = address(0x80F);
    uint256 internal constant ATTACK = 500_000e6;

    address internal _attacker = makeAddr("ATTACKER");
    HyperCorePendingReader internal _pendingReader;

    function setUp() public override {
        super.setUp();
        _pendingReader = new HyperCorePendingReader();
        vm.prank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _attacker, 0);
        _usdc.mint(_attacker, ATTACK);
        vm.prank(_attacker);
        _usdc.approve(address(_vault), ATTACK);
    }

    // ------------------------------------------------------------------
    // a. same-layout semantic change (accountValue x100) can no longer reprice the vault
    // ------------------------------------------------------------------
    function testAccountValueScaledX100RevertsUserFlowsAndActions() public {
        _activateWithPerpMargin();
        uint256 navBefore = _refreshAndTotalAssets();
        HyperCoreLib.AccountMarginSummary memory s = HyperCoreLib.accountMarginSummary(0, address(_vault));
        assertGt(s.accountValue, 0, "perp leg funded");

        vm.mockCall(
            MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(uint32(0), address(_vault)),
            abi.encode(s.accountValue * 100, s.marginUsed, s.ntlPos, s.rawUsd)
        );
        bytes4 sel = HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector;

        _expectUserFlowsRevert(abi.encodePacked(sel), true);

        // an ALPHA action cannot launder the repriced value through the pending cache
        uint256 cachedBefore = _vault.totalAssetsInMarket(MARKET_ID);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 1e6, toPerp: true})
            )
        );
        vm.expectPartialRevert(sel);
        _vault.execute(actions);
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), cachedBefore, "stored market value untouched");

        vm.clearMockedCalls();
        assertEq(_refreshAndTotalAssets(), navBefore, "flows resume once the precompile is honest");
    }

    // ------------------------------------------------------------------
    // b. an empty reply stays fail-closed with the precompile error
    // ------------------------------------------------------------------
    function testEmptyMarginSummaryReplyStaysFailClosed() public {
        _activateWithPerpMargin();
        vm.mockCall(MARGIN_SUMMARY_PRECOMPILE, abi.encode(uint32(0), address(_vault)), bytes(""));
        bytes memory err = abi.encodeWithSelector(
            HyperCoreLib.HyperCorePrecompileFailed.selector,
            MARGIN_SUMMARY_PRECOMPILE
        );

        _expectUserFlowsRevert(err, false);

        vm.clearMockedCalls();
        _assertUserFlowsWork();
    }

    // ------------------------------------------------------------------
    // c. genuine Core value moves: inside the band pass, outside trip (symmetric)
    // ------------------------------------------------------------------
    function testGenuineMovesInsideAndOutsideDefaultBand() public {
        _activateWithSpot(100_000e6);
        bytes4 sel = HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector;
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 100_000e8);

        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 140_000e8); // +40%
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 140_000e6, 2e6, "+40% accepted and stored");

        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 224_000e8); // +60% of 140k
        _expectUserFlowsRevert(abi.encodePacked(sel), true);

        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 56_000e8); // -60% of 140k
        _expectUserFlowsRevert(abi.encodePacked(sel), true);

        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 70_000e8); // -50% of the stored 140k
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 70_000e6, 2e6, "50% is inside the band");
    }

    // ------------------------------------------------------------------
    // d. recovery by the Atomist: raise, refresh, restore
    // ------------------------------------------------------------------
    function testAtomistRecoveryRaiseRefreshRestore() public {
        _activateWithSpot(100_000e6);
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 400_000e8); // genuine 4x
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);

        _grantNavJump(true, 1_000_000);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 400_000e6, 2e6, "refresh stores the new value");

        _grantNavJump(true, 5000);
        _assertUserFlowsWork();
    }

    // ------------------------------------------------------------------
    // e. legitimate transfers never trip the breaker
    // ------------------------------------------------------------------
    function testDepositMultiplyingCoreValueDoesNotTrip() public {
        _activateWithSpot(50_000e6);
        _coreDeposit(500_000e6);
        _settle(2);
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive());
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 550_000e6, 2e6);
        _assertUserFlowsWork();
    }

    function testBridgeOfNinetyFivePercentDoesNotTrip() public {
        _activateWithSpot(100_000e6);
        uint256 evmBefore = _usdc.balanceOf(address(_vault));
        _sendAssetToEvm(95_000e8);
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        CoreSimulatorLib.nextBlock();
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore + 95_000e6, "EVM credit landed");
        assertFalse(_isPendingLive());
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 5_000e6, 2e6);
        _assertUserFlowsWork();
    }

    function testFirstActivationDepositPassesWithZeroStoredValue() public {
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 0);
        _coreDeposit(100_000e6);
        _settle(2);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 100_000e6, 2e6);
        _assertUserFlowsWork();
    }

    // ------------------------------------------------------------------
    // f. a transfer that never lands and exceeds the band freezes user flows (intended)
    // ------------------------------------------------------------------
    function testRejectedDepositOverThresholdFreezesUserFlows() public {
        _activateWithSpot(100_000e6);
        _coreDeposit(200_000e6);
        // Core rejects the credit: the spot balance never grows
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 100_000e8);
        uint64 pendingUntil = _pendingUntil();
        vm.roll(block.number + 1);
        vm.warp(pendingUntil + 600);
        assertFalse(_isPendingLive(), "timeout opens the gate");
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
    }

    function testRejectedBridgeOverThresholdFreezesUserFlows() public {
        _activateWithSpot(200_000e6);
        _sendAssetToEvm(150_000e8); // Core never executes it (no nextBlock)
        uint64 pendingUntil = _pendingUntil();
        vm.roll(block.number + 1);
        vm.warp(pendingUntil + 600);
        assertFalse(_isPendingLive(), "timeout opens the gate");
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
    }

    // ------------------------------------------------------------------
    // g. configuration
    // ------------------------------------------------------------------
    function testZeroConfiguredMaxJumpReverts() public {
        _activateWithSpot(100_000e6);
        _grantNavJump(true, 0);
        vm.prank(_atomist);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, uint240(0))
        );
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testAboveUint64ConfiguredMaxJumpReverts() public {
        _activateWithSpot(100_000e6);
        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantNavJump(true, tooLarge);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, tooLarge));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testUnsetConfigUsesDefaultFiftyPercentAndMatchesExplicit() public {
        _activateWithSpot(100_000e6);
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 100_000e8);
        _refreshAndTotalAssets();
        // stored 100_000; live 150_002 > 150_000 (+50%)
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 150_002e8);
        bytes memory err = abi.encodeWithSelector(
            HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector,
            100_000e18,
            150_002e18,
            5000
        );
        vm.prank(_atomist);
        vm.expectRevert(err);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));

        _grantNavJump(true, 5000);
        vm.prank(_atomist);
        vm.expectRevert(err);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));

        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 150_000e8); // live 150_000, exactly +50%, inside the band
        _refreshAndTotalAssets();
    }

    function testMissingOraclePriceRevertsReferenceUnavailable() public {
        _activateWithSpot(100_000e6);
        // Value the account through the perp leg only so the spot-token oracle read is skipped
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 0);
        CoreSimulatorLib.forcePerpBalance(address(_vault), 50_000e6);
        vm.mockCall(
            address(_priceManager),
            abi.encodeWithSignature("getAssetPrice(address)", address(_usdc)),
            abi.encode(uint256(0), uint256(8))
        );
        vm.expectRevert(HyperCoreValuationLib.HyperCoreNavJumpReferenceUnavailable.selector);
        _coreDeposit(1e6);
        vm.clearMockedCalls();
    }

    // ------------------------------------------------------------------
    // h. IL-8766: absolute tolerance (NavJumpFloorUsd6) against donations to a small stored value
    // ------------------------------------------------------------------
    uint256 internal constant DONATION = 3_000e6; // ~60% of the ~5_000e6 stored value after a 95% bridge
    uint240 internal constant FLOOR_ABOVE_DONATION = 10_000e6;

    /// @dev PoC 9eb0a219 port: bridge 95% back to EVM, then a third party credits 60% of the stored value on Core
    ///      (modelled by crediting the vault's Core spot balance, which is what an inbound `spotSend` does).
    function testDonationOverHalfOfSmallStoredValueFreezesVaultWithoutFloor() public {
        _bridgeNinetyFivePercentThenDonate(DONATION);
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
    }

    function testDonationBelowFloorKeepsDepositRedeemAndMarginEnterWorking() public {
        _grantFloor(true, FLOOR_ABOVE_DONATION);
        _bridgeNinetyFivePercentThenDonate(DONATION);
        uint256 storedBefore = _vault.totalAssetsInMarket(MARKET_ID);

        vm.prank(_attacker);
        assertGt(_vault.deposit(1e6, _attacker), 0, "deposit passes");
        uint256 shares = _vault.convertToShares(1_000e6);
        vm.prank(_user);
        assertGt(_vault.redeem(shares, _user, _user), 0, "redeem passes");

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 1e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        _settle(2);

        _refreshAndTotalAssets();
        assertApproxEqAbs(
            _vault.totalAssetsInMarket(MARKET_ID),
            storedBefore + DONATION,
            2e6,
            "refresh books the donation"
        );
    }

    function testDropBelowFloorEvenOverHalfDoesNotTrip() public {
        _grantFloor(true, FLOOR_ABOVE_DONATION);
        _bridgeNinetyFivePercentThenDonate(0);
        // stored ~5_000e6 -> live ~1_000e6: -80%, absolute move ~4_000e6 < floor
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 1_000e8);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 1_000e6, 2e6, "drop inside the floor accepted");
    }

    function testDonationAboveFloorAndAboveHalfStillTrips() public {
        _grantFloor(true, 1_000e6);
        _bridgeNinetyFivePercentThenDonate(DONATION);
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
    }

    function testAccountValueScaledX100StillTripsWithFloorSet() public {
        _grantFloor(true, FLOOR_ABOVE_DONATION);
        _activateWithPerpMargin();
        _refreshAndTotalAssets();
        HyperCoreLib.AccountMarginSummary memory s = HyperCoreLib.accountMarginSummary(0, address(_vault));
        assertGt(s.accountValue, 0, "perp leg funded");
        vm.mockCall(
            MARGIN_SUMMARY_PRECOMPILE,
            abi.encode(uint32(0), address(_vault)),
            abi.encode(s.accountValue * 100, s.marginUsed, s.ntlPos, s.rawUsd)
        );
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
        vm.clearMockedCalls();
    }

    function testDropAboveFloorAndAboveHalfTrips() public {
        _grantFloor(true, 1_000e6);
        _activateWithSpot(100_000e6);
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 20_000e8); // -80%, ~80_000e6 > floor
        _expectUserFlowsRevert(abi.encodePacked(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector), true);
    }

    function testFloorAboveUint64Reverts() public {
        _activateWithSpot(100_000e6);
        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantFloor(true, tooLarge);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, tooLarge));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testFloorAboveUint64RevertsAtZeroStoredValue() public {
        // first activation: nothing stored yet, the floor is still validated before the stored == 0 early return
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 0, "nothing stored before activation");
        uint240 tooLarge = uint240(type(uint64).max) + 1;
        _grantFloor(true, tooLarge);
        vm.prank(_atomist);
        vm.expectRevert(abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreNavJumpConfigInvalid.selector, tooLarge));
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testFloorAtUint64MaxIsAccepted() public {
        _activateWithSpot(100_000e6);
        _grantFloor(true, uint240(type(uint64).max));
        _refreshAndTotalAssets();
    }

    function testFloorConfigKeyCodecRoundTripAndUpperBound() public {
        assertEq(
            uint8(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6),
            11,
            "appended after MaxMarkOracleDeviationBps"
        );
        bytes32 word = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6, 123e6);
        assertEq(word, bytes32((uint256(5) << 248) | (uint256(11) << 240) | 123e6));
        (HyperCoreSubstrateLib.ConfigKey key, uint240 value) = HyperCoreSubstrateLib.decodeConfig(word);
        assertEq(uint8(key), 11);
        assertEq(uint256(value), 123e6);

        vm.expectRevert(abi.encodeWithSelector(HyperCoreSubstrateLib.HyperCoreInvalidConfigKey.selector, uint8(12)));
        this.decodeConfigExternal(bytes32((uint256(5) << 248) | (uint256(12) << 240)));
    }

    function testDuplicateFloorConfigReverts() public {
        _activateWithSpot(100_000e6);
        bytes32[] memory substrates = _fixtureSubstrates(2);
        substrates[8] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6, 1e6);
        substrates[9] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6, 2e6);
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
        vm.prank(_atomist);
        vm.expectRevert(
            abi.encodeWithSelector(
                HyperCoreSubstrateLib.HyperCoreDuplicateConfig.selector,
                HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6
            )
        );
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function decodeConfigExternal(bytes32 word_) external pure {
        HyperCoreSubstrateLib.decodeConfig(word_);
    }

    /// @dev Activates with 100_000 USDC on Core, bridges 95% back to EVM (stored ~5_000e6 after the refresh), then
    ///      credits `donation_` USD6 to the vault's Core spot balance without any refresh.
    function _bridgeNinetyFivePercentThenDonate(uint256 donation_) internal {
        _activateWithSpot(100_000e6);
        _sendAssetToEvm(95_000e8);
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive());
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 5_000e6, 2e6, "small stored value");
        if (donation_ != 0) {
            uint64 current = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total;
            CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, current + uint64(donation_ * 100));
        }
    }

    function _fixtureSubstrates(uint256 extra_) internal view returns (bytes32[] memory substrates) {
        substrates = new bytes32[](8 + extra_);
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
    }

    function _grantFloor(bool set_, uint240 floorUsd6_) internal {
        bytes32[] memory substrates = _fixtureSubstrates(set_ ? 1 : 0);
        if (set_) {
            substrates[8] = HyperCoreSubstrateLib.encodeConfig(
                HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6,
                floorUsd6_
            );
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
    }

    function _activateWithSpot(uint256 usd6_) internal {
        _coreDeposit(usd6_);
        _settle(2);
        _refreshAndTotalAssets();
        // the first Core credit loses 1 USDC to the activation fee
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), usd6_, 2e6, "stored value follows the Core account");
    }

    function _activateWithPerpMargin() internal {
        _activateWithSpot(100_000e6);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        _settle(2);
    }

    /// @dev Re-grants the full fixture substrate set, optionally with a `MaxNavJumpBps` entry.
    function _grantNavJump(bool set_, uint240 bps_) internal {
        bytes32[] memory substrates = new bytes32[](set_ ? 9 : 8);
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
        if (set_) {
            substrates[8] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.MaxNavJumpBps, bps_);
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
    }

    /// @dev A user deposit, a user redeem and an Atomist refresh must all revert with `err_` (a 4-byte
    ///      selector prefix when `partial_`, otherwise the exact revert data).
    function _expectUserFlowsRevert(bytes memory err_, bool partial_) internal {
        vm.prank(_attacker);
        _expect(err_, partial_);
        _vault.deposit(1e6, _attacker);

        uint256 shares = _vault.balanceOf(_user) / 10;
        vm.prank(_user);
        _expect(err_, partial_);
        _vault.redeem(shares, _user, _user);

        vm.prank(_atomist);
        _expect(err_, partial_);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function _expect(bytes memory err_, bool partial_) private {
        if (partial_) vm.expectPartialRevert(bytes4(err_));
        else vm.expectRevert(err_);
    }

    function _assertUserFlowsWork() internal {
        vm.prank(_attacker);
        assertGt(_vault.deposit(1e6, _attacker), 0, "deposit works");
        // a settled transfer is latched by the pre-hooks, so the redeem size no longer matters
        uint256 shares = _vault.convertToShares(1_000e6);
        vm.prank(_user);
        assertGt(_vault.redeem(shares, _user, _user), 0, "redeem works");
        _refreshAndTotalAssets();
    }

    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isActionPending, ())
        );
        return abi.decode(r.data, (bool));
    }

    function _pendingUntil() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));
    }

    function _coreDeposit(uint256 amount_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
            )
        );
        _vault.execute(actions);
    }

    function _sendAssetToEvm(uint64 amountWei_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_sendFuse),
            abi.encodeWithSelector(
                HyperCoreSendFuse.enterSendAsset.selector,
                HyperCoreSendFuseSendAssetData({
                    destination: HyperCoreLib.systemAddress(USDC_TOKEN),
                    sourceDex: HyperCoreLib.SPOT_DEX,
                    destinationDex: HyperCoreLib.SPOT_DEX,
                    tokenIndex: USDC_TOKEN,
                    amountWei: amountWei_
                })
            )
        );
        _vault.execute(actions);
    }
}
