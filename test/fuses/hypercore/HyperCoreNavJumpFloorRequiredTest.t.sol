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

/// @notice IL-9597: `Config{NavJumpFloorUsd6}` must be granted explicitly. An unset key reverts every NAV jump check
///         (market refresh and action fuses) with `HyperCoreNavJumpFloorNotConfigured`, an explicit 0 keeps the
///         purely relative breaker, an explicit value above the donation keeps a small vault from freezing.
contract HyperCoreNavJumpFloorRequiredTest is HyperCoreEffectSettlementBase {
    /// @dev Selector by signature so that the test also compiles against a build without the error.
    bytes4 internal constant NOT_CONFIGURED = bytes4(keccak256("HyperCoreNavJumpFloorNotConfigured()"));

    // ------------------------------------------------------------------
    // unset floor: fail closed on the first use, even while the stored value is still zero
    // ------------------------------------------------------------------
    function testUnsetFloorRevertsMarketRefreshWhileStoredValueIsZero() public {
        _grantFixture(false, 0);
        assertEq(_vault.totalAssetsInMarket(MARKET_ID), 0, "nothing stored yet");

        vm.prank(_atomist);
        vm.expectRevert(NOT_CONFIGURED);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    function testUnsetFloorRevertsActionFuseThatSnapshotsLiveValue() public {
        _grantFixture(false, 0);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: 10e6})
            )
        );
        vm.expectRevert(NOT_CONFIGURED);
        _vault.execute(actions);
    }

    function testUnsetFloorRevertsAfterActivationToo() public {
        _grantFixture(true, 0);
        _coreDeposit(10e6);
        _settle(2);
        _refreshAndTotalAssets();
        assertGt(_vault.totalAssetsInMarket(MARKET_ID), 0, "stored value present");

        _grantFixture(false, 0);
        vm.prank(_atomist);
        vm.expectRevert(NOT_CONFIGURED);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // explicit 0: accepted, behaves like the purely relative breaker
    // ------------------------------------------------------------------
    function testExplicitZeroFloorIsAcceptedAndDonationTripsRelativeBreaker() public {
        _grantFixture(true, 0);
        _activateSmall();

        _donate(8e6); // ~90% of the ~9e6 stored value, above the default 50% band
        vm.prank(_atomist);
        vm.expectPartialRevert(HyperCoreValuationLib.HyperCoreNavJumpExceeded.selector);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // ------------------------------------------------------------------
    // explicit floor above the donation: no freeze
    // ------------------------------------------------------------------
    function testExplicitFloorAboveDonationDoesNotFreeze() public {
        _grantFixture(true, 10e6);
        _activateSmall();

        _donate(8e6);
        uint256 nav = _refreshAndTotalAssets();
        assertGt(nav, 0, "refresh booked the donation");
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 17e6, 2e6, "donation booked");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _activateSmall() internal {
        _coreDeposit(10e6);
        _settle(2);
        _refreshAndTotalAssets();
        assertApproxEqAbs(_vault.totalAssetsInMarket(MARKET_ID), 10e6, 2e6, "small stored value");
    }

    function _donate(uint256 usd6_) internal {
        uint64 current = HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total;
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, current + uint64(usd6_ * 100));
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

    /// @dev Re-grants the fixture substrate set for market 55, with or without the floor config.
    function _grantFixture(bool withFloor_, uint240 floorUsd6_) internal {
        bytes32[] memory substrates = new bytes32[](withFloor_ ? 9 : 8);
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
        if (withFloor_) {
            substrates[8] = HyperCoreSubstrateLib.encodeConfig(
                HyperCoreSubstrateLib.ConfigKey.NavJumpFloorUsd6,
                floorUsd6_
            );
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_ID, substrates);
    }
}
