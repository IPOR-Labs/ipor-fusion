// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreOrderFuse, HyperCoreOrderFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @notice IL-8528 / IL-8543 compatibility regression suite. REPORTED mode was removed in IL-8543 and the
///         `Config{SettlementMode}` / `Config{WindowOrderSeconds}` keys are reserved and ignored. A vault that
///         was configured with the legacy keys (here `SettlementMode = 2`, the former REPORTED value) must still
///         decode its config, settle transfers on their observed effect (IL-8526: cross-domain transfers wait for
///         the balance effect, intra-Core transfers settle by time) and treat orders as TIMING (no pending record,
///         one-Core-block mini-gate), without any settlement report.
contract HyperCoreTransferSettlementModeTest is HyperCoreEffectSettlementBase {
    address internal constant CORE_USER_EXISTS_PRECOMPILE = address(0x810);

    HyperCorePendingReader internal _pendingReader;

    function setUp() public override {
        super.setUp();
        _pendingReader = new HyperCorePendingReader();
        _grantSubstratesWithLegacyKeys(2, 30);
        _usdc.mint(_secondUser, 100_000e6);
        vm.prank(_secondUser);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    function testLegacyReportedKeyDepositStaysPendingUntilCoreCreditThenSettles() public {
        _executeDeposit(100_000e6);
        assertTrue(_isPendingLive(), "deposit enqueued");
        uint64 pendingUntil = uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));

        // Core credit delayed: the vault's Core account does not exist yet.
        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(address(_vault)), abi.encode(false));
        _settleWindowOnly(2);
        assertTrue(_isPendingLive(), "a deposit does not settle by time alone");

        bytes memory err = abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil);
        vm.prank(_secondUser);
        vm.expectRevert(err);
        _vault.deposit(1e6, _secondUser);

        // Core credit lands: settles with no report.
        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "settles on the observed Core credit, no report needed");
        vm.prank(_secondUser);
        assertGt(_vault.deposit(1e6, _secondUser), 0);
        vm.prank(_user);
        assertGt(_vault.redeem(1e6, _user, _user), 0);
    }

    function testLegacyReportedKeyBridgeToEvmSettlesOnEvmCredit() public {
        _executeDeposit(100_000e6);
        _settle(2);
        assertFalse(_isPendingLive());

        uint256 evmBefore = _usdc.balanceOf(address(_vault));
        _executeSendToEvm(50_000e8);
        assertTrue(_isPendingLive(), "bridge enqueued");
        uint64 pendingUntil = uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));

        // Window + later L1 block pass, but the EVM credit has not landed.
        _settleWindowOnly(2);
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore, "no EVM credit yet");
        assertTrue(_isPendingLive(), "a bridge does not settle by time alone");
        vm.prank(_secondUser);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        _vault.deposit(1e6, _secondUser);

        CoreSimulatorLib.nextBlock();
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore + 50_000e6, "EVM credit landed");
        assertFalse(_isPendingLive(), "settles on the observed EVM credit, no report needed");
        vm.prank(_secondUser);
        assertGt(_vault.deposit(1e6, _secondUser), 0);
    }

    /// @dev Intended: a margin move is atomic inside Core (no in-transit value), so it settles by time even when
    ///      the legacy SettlementMode key is REPORTED.
    function testLegacyReportedKeyMarginMoveSettlesByTime() public {
        _executeDeposit(100_000e6);
        _settle(2);

        _executeMargin(50_000e6);
        assertTrue(_isPendingLive(), "margin move enqueued");

        // Core has not processed the action; window + later L1 block alone settle it.
        _settleWindowOnly(2);
        assertFalse(_isPendingLive(), "margin move settles by time, no report");
        vm.prank(_secondUser);
        assertGt(_vault.deposit(1e6, _secondUser), 0);
    }

    /// @dev The legacy `SettlementMode = 2` key is ignored: an order creates no pending record (TIMING behavior),
    ///      only the one-Core-block mini-gate, and users flow again one Core block later.
    function testLegacyReportedKeyOrderBehavesAsTiming() public {
        _openOrderPrerequisites();
        _placeOrder();
        assertFalse(_isPendingLive(), "no pending record for an order, whatever the legacy key says");
        assertTrue(_isOrderInFlightLive(), "mini-gate is open for the current Core block");

        CoreSimulatorLib.nextBlock();
        assertFalse(_isOrderInFlightLive());
        vm.prank(_secondUser);
        assertGt(_vault.deposit(1e6, _secondUser), 0);
    }

    /// @dev Legacy keys with any value (an invalid mode, a zero order window) still decode and are ignored.
    function testLegacyKeysWithAnyValueAreIgnoredByOrdersAndCancels() public {
        _grantSubstratesWithLegacyKeys(7, 0);
        _openOrderPrerequisites();
        _placeOrder();
        assertFalse(_isPendingLive(), "order placed with an invalid legacy mode and zero window");
        CoreSimulatorLib.nextBlock();
        _run(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByOid.selector,
                HyperCoreCancelFuseCancelByOidData({asset: HYPE_PERP, oid: 1})
            )
        );
        assertFalse(_isPendingLive(), "cancel creates no pending record");

        // A vault without the legacy keys behaves the same way.
        _grantSubstrates();
        CoreSimulatorLib.nextBlock();
        _run(
            address(_cancelFuse),
            abi.encodeWithSelector(
                HyperCoreCancelFuse.enterCancelByOid.selector,
                HyperCoreCancelFuseCancelByOidData({asset: HYPE_PERP, oid: 1})
            )
        );
        assertFalse(_isPendingLive());
    }

    function _openOrderPrerequisites() internal {
        _executeDeposit(100_000e6);
        _settle(2);
        _executeMargin(50_000e6);
        _settle(2);
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);
    }

    function _placeOrder() internal {
        _run(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: false,
                    limitPx: 45e8,
                    sz: 1e8,
                    reduceOnly: false,
                    tif: HyperCoreLib.TIF_GTC,
                    cloid: CLOID_1
                })
            )
        );
    }

    function _isOrderInFlightLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isOrderInFlight, ())
        );
        return abi.decode(r.data, (bool));
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev Passes the transfer window and a later L1 block WITHOUT letting the simulator process Core actions.
    function _settleWindowOnly(uint256 windowSeconds_) internal {
        vm.warp(block.timestamp + windowSeconds_ + 1);
        vm.roll(block.number + 1);
    }

    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(address(_pendingReader), abi.encodeCall(HyperCorePendingReader.isActionPending, ()));
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

    function _executeSendToEvm(uint64 amountWei_) internal {
        _run(
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
    }

    function _run(address fuse_, bytes memory data_) internal {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        _vault.execute(actions);
    }
}
