// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {HyperCoreDepositFuse, HyperCoreDepositFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreOrderFuse, HyperCoreOrderFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @notice IL-8527 regression suite (ported from the reviewer PoC `testPoC_M1_M2_UsersAndCancelBlockedForOrderWindow`):
///         TIMING orders and cancels create no pending record, so users and the manager are no longer locked for
///         `WindowOrderSeconds`. Only a one-Core-block mini-gate remains after an order. (IL-8543 removed REPORTED mode.)
contract HyperCoreOrderLivenessTest is HyperCoreEffectSettlementBase {
    HyperCorePendingReader internal _pendingReader;

    function setUp() public override {
        super.setUp();
        _pendingReader = new HyperCorePendingReader();
        _usdc.mint(_secondUser, 100_000e6);
        vm.prank(_secondUser);
        _usdc.approve(address(_vault), type(uint256).max);

        // Activate the Core account and fund perp margin (transfers settle by time + effect).
        _executeDeposit(100_000e6);
        _settle(2);
        _executeMargin(50_000e6);
        _settle(2);
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);
    }

    // ------------------------------------------------------------------
    // TIMING: M1 (users) and M2 (cancel) regression
    // ------------------------------------------------------------------

    function testTimingOrderBlocksUsersOnlyUntilNextCoreBlock() public {
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2); // non-crossing, rests on the book
        uint64 orderBlock = uint64(block.number);
        assertFalse(_isPendingLive(), "TIMING order creates no pending record");
        assertTrue(_isOrderInFlightLive(), "mini-gate is open for the current Core block");

        bytes memory err = abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderInFlight.selector, orderBlock);
        vm.prank(_secondUser);
        vm.expectRevert(err);
        _vault.deposit(1e6, _secondUser);
        vm.prank(_user);
        vm.expectRevert(err);
        _vault.redeem(1e8, _user, _user);

        // One Core block later (no window wait) users flow again.
        CoreSimulatorLib.nextBlock();
        assertFalse(_isOrderInFlightLive(), "gate closed after the next Core block");
        vm.prank(_secondUser);
        uint256 shares = _vault.deposit(1e6, _secondUser);
        assertGt(shares, 0);
        vm.prank(_user);
        assertGt(_vault.redeem(1e8, _user, _user), 0);
    }

    function testTimingCancelPassesInNextTxAndDoesNotBlockUsers() public {
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2);
        // Same Core block (no nextBlock): the manager can cancel immediately.
        _executeCancel(1);
        assertFalse(_isPendingLive(), "TIMING cancel creates no pending record");

        // The cancel does not extend the gate beyond the order's Core block.
        CoreSimulatorLib.nextBlock();
        vm.prank(_secondUser);
        _vault.deposit(1e6, _secondUser);
        // And a cancel is available any time afterwards, repeatedly, without blocking users.
        _executeCancel(1);
        _executeCancel(1);
        vm.prank(_secondUser);
        _vault.deposit(1e6, _secondUser);
    }

    function testTimingOrderRateLimitedPerCoreBlock() public {
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2);
        vm.expectRevert(
            abi.encodeWithSelector(HyperCorePendingLib.HyperCoreOrderRateLimited.selector, uint64(block.number))
        );
        _executeOrder(false, 46e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_3);

        CoreSimulatorLib.nextBlock();
        _executeOrder(false, 46e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_3);
    }

    function testBalanceFuseReturnsLiveValueRightAfterTimingOrder() public {
        uint256 navBefore = _refreshAndTotalAssets();
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2);
        uint256 navAfter = _refreshAndTotalAssets();
        assertGt(navAfter, navBefore - 2e6, "NAV must not drop (balance fuse must not return the empty cache)");
        assertApproxEqAbs(navAfter, navBefore, 2e6);
    }

    function testLastOrderL1BlockPersistsAcrossTransfers() public {
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2);
        uint64 orderBlock = uint64(block.number);
        // A transfer enqueue/settle in a later block must not reset the persistent field.
        CoreSimulatorLib.nextBlock();
        _executeMargin(1_000e6);
        _settle(2);
        assertEq(uint64(uint256(vm.load(address(_vault), bytes32(uint256(PENDING_SLOT) + 9)))), orderBlock);
    }

    // ------------------------------------------------------------------
    // A pending transfer still blocks orders and cancels
    // ------------------------------------------------------------------

    function testPendingTransferBlocksOrderAndCancel() public {
        _executeMargin(1_000e6);
        assertTrue(_isPendingLive());
        uint64 until = uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));
        bytes memory err = abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, until);
        vm.expectRevert(err);
        _executeOrder(false, 45e8, 1e8, HyperCoreLib.TIF_GTC, CLOID_2);
        vm.expectRevert(err);
        _executeCancel(1);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(address(_pendingReader), abi.encodeCall(HyperCorePendingReader.isActionPending, ()));
        return abi.decode(r.data, (bool));
    }

    function _isOrderInFlightLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isOrderInFlight, ())
        );
        return abi.decode(r.data, (bool));
    }

    function _executeDeposit(uint256 amount_) internal {
        _run(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
            )
        );
    }

    function _executeMargin(uint64 usd6_) internal {
        _run(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: usd6_, toPerp: true})
            )
        );
    }

    function _executeOrder(bool isBuy_, uint64 limitPx_, uint64 sz_, uint8 tif_, uint128 cloid_) internal {
        _run(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: isBuy_,
                    limitPx: limitPx_,
                    sz: sz_,
                    reduceOnly: false,
                    tif: tif_,
                    cloid: cloid_
                })
            )
        );
    }

    function _executeCancel(uint64 oid_) internal {
        _run(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByOid.selector,
                HyperCoreCancelFuseCancelByOidData({asset: HYPE_PERP, oid: oid_})
            )
        );
    }

    function _run(address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        _vault.execute(actions);
    }
}
