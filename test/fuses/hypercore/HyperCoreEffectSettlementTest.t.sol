// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {ReadResult} from "../../../contracts/universal_reader/UniversalReader.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreMarginFuse, HyperCoreMarginFuseEnterData} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";

/// @notice IL-8526 regression suite on a FusionFactory vault + offline Core simulator: the pending gate of an
///         EVM -> Core deposit and a Core -> EVM bridge must stay closed until the cross-domain credit has
///         actually landed (or the timeout passes). Ported from the reviewer's H2 PoC, which proved the
///         time-only gate let an attacker deposit at a deflated NAV while 100k was in transit.
contract HyperCoreEffectSettlementTest is HyperCoreEffectSettlementBase {
    uint256 internal constant ATTACK = 500_000e6;
    address internal constant CORE_USER_EXISTS_PRECOMPILE = address(0x810);

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
    // EVM -> Core: the attack from the H2 PoC no longer works
    // ------------------------------------------------------------------
    function testAttackerDepositRevertsWhileCoreCreditNotLanded() public {
        uint256 navBefore = _vault.totalAssets();
        _coreDeposit(100_000e6);
        assertTrue(_isPendingLive(), "deposit enqueued");
        uint64 pendingUntil = _pendingUntil();

        // Window and L1 block gates pass but Core has not processed the transfer: model Core latency by the
        // first-deposit reality, the vault's Core account does not exist until the credit is processed.
        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(address(_vault)), abi.encode(false));
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        assertTrue(_isPendingLive(), "gate stays closed until the credit lands");

        bytes memory pendingErr = abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil);
        vm.prank(_attacker);
        vm.expectRevert(pendingErr);
        _vault.deposit(ATTACK, _attacker);
        vm.prank(_user);
        vm.expectRevert(pendingErr);
        _vault.redeem(1e8, _user, _user);

        // Core processes the queued transfer.
        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit landed, gate open");

        uint256 navAfterCredit = _refreshAndTotalAssets();
        assertApproxEqAbs(navAfterCredit, navBefore, 2e6, "NAV ~flat (only the Core activation fee)");

        vm.prank(_attacker);
        uint256 shares = _vault.deposit(ATTACK, _attacker);
        vm.prank(_attacker);
        uint256 got = _vault.redeem(shares, _attacker, _attacker);
        assertApproxEqRel(got, ATTACK, 0.0001e18, "attacker gets back what was deposited: no free value");
    }

    /// @dev IL-8532 (reviewer PoC port): WindowTransferSeconds = 1 is the smallest accepted window, but since
    ///      IL-8526 it is only a minimum wait; the gate stays closed until the credit lands or the timeout.
    function testWindowOneSecondDoesNotOpenGateBeforeCreditLands() public {
        _grantSubstratesWindows(1);
        uint256 navBefore = _vault.totalAssets();
        _coreDeposit(100_000e6);
        assertTrue(_isPendingLive(), "deposit enqueued");
        uint64 pendingUntil = _pendingUntil();

        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(address(_vault)), abi.encode(false));
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);
        assertTrue(_isPendingLive(), "1 s window + one L1 block must not settle without the effect");

        bytes memory pendingErr = abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil);
        vm.prank(_attacker);
        vm.expectRevert(pendingErr);
        _vault.deposit(ATTACK, _attacker);
        assertApproxEqAbs(_vault.totalAssets(), navBefore, 2e6, "NAV not deflated by the 100k in transit");
        assertGt(_vault.totalAssets(), 990_000e6, "stays ~1,000,000 from the cache, not ~900,000");

        vm.clearMockedCalls();
        CoreSimulatorLib.nextBlock();
        assertFalse(_isPendingLive(), "credit landed, gate open");
        assertApproxEqAbs(_refreshAndTotalAssets(), navBefore, 2e6, "NAV ~flat after the credit");
    }

    function testDepositGateOpensOnTimeoutWhenCreditNeverLands() public {
        _coreDeposit(100_000e6);
        uint64 pendingUntil = _pendingUntil();
        vm.mockCall(CORE_USER_EXISTS_PRECOMPILE, abi.encode(address(_vault)), abi.encode(false));
        vm.roll(block.number + 1);

        vm.warp(pendingUntil + 599);
        assertTrue(_isPendingLive(), "still inside the timeout");
        vm.warp(pendingUntil + 600);
        assertFalse(_isPendingLive(), "timeout: a rejected transfer cannot freeze the vault");
        vm.clearMockedCalls();
    }

    // ------------------------------------------------------------------
    // Core -> EVM: EVM credit late keeps user flows blocked
    // ------------------------------------------------------------------
    function testBridgeToEvmBlocksUserFlowsUntilEvmCreditLands() public {
        _coreDeposit(100_000e6);
        _settle(2);
        assertFalse(_isPendingLive());

        uint256 evmBefore = _usdc.balanceOf(address(_vault));
        _sendAssetToEvm(50_000e8);
        assertTrue(_isPendingLive(), "bridge enqueued");
        uint64 pendingUntil = _pendingUntil();

        // Time + L1 block pass, but the simulator has not processed the CoreWriter action: Core is not debited
        // and the EVM balance has not been credited yet.
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore, "no EVM credit yet");
        assertTrue(_isPendingLive(), "gate closed while the EVM credit is missing");

        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        _vault.deposit(ATTACK, _attacker);

        // Core executes the send: the vault's ERC20 balance is credited.
        CoreSimulatorLib.nextBlock();
        assertEq(_usdc.balanceOf(address(_vault)), evmBefore + 50_000e6, "EVM credit landed");
        assertFalse(_isPendingLive(), "gate open once the EVM credit is observed");

        uint256 nav = _refreshAndTotalAssets();
        assertApproxEqAbs(nav, 1_000_000e6, 2e6, "NAV ~flat across the round trip");
        vm.prank(_attacker);
        assertGt(_vault.deposit(ATTACK, _attacker), 0);
    }

    function testBridgeGateOpensOnTimeoutWhenEvmCreditNeverArrives() public {
        _coreDeposit(100_000e6);
        _settle(2);
        _sendAssetToEvm(50_000e8);
        uint64 pendingUntil = _pendingUntil();
        vm.roll(block.number + 1);
        vm.warp(pendingUntil + 599);
        assertTrue(_isPendingLive());
        vm.warp(pendingUntil + 600);
        assertFalse(_isPendingLive());
    }

    // ------------------------------------------------------------------
    // Regression: margin moves remain purely time-based
    // ------------------------------------------------------------------
    function testMarginMoveStillSettlesByTimeAlone() public {
        _coreDeposit(100_000e6);
        _settle(2);

        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        assertTrue(_isPendingLive(), "margin move enqueued");

        // Core has not processed the action yet (no nextBlock): time + L1 block alone must settle it.
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        assertFalse(_isPendingLive(), "margin move settles by time, no effect to wait for");
    }

    // ------------------------------------------------------------------
    // Settlement latch (IL-8518): a settled transfer must not re-open when balances move afterwards
    // ------------------------------------------------------------------
    function testBridgeSettledThenUserRedeemBelowExpectedDoesNotReopenPending() public {
        _coreDeposit(100_000e6);
        _settle(2);
        _sendAssetToEvm(50_000e8);
        CoreSimulatorLib.nextBlock();
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        uint256 expectedBalance = _expectedBalance();
        assertGe(_usdc.balanceOf(address(_vault)), expectedBalance, "EVM credit landed");

        // A large redeem lowers the EVM USDC below the bridge's expectedBalance.
        uint256 shares = _vault.balanceOf(_user) / 5;
        vm.prank(_user);
        assertGt(_vault.redeem(shares, _user, _user), 0, "redeem after settlement works");
        assertLt(_usdc.balanceOf(address(_vault)), expectedBalance, "EVM balance dropped below the old effect");

        // The record was latched by the redeem's pre-hook: nothing is pending any more.
        assertFalse(_isPending(), "record cleared");
        assertFalse(_isPendingLive(), "not pending after the balance drop");

        vm.prank(_attacker);
        assertGt(_vault.deposit(1_000e6, _attacker), 0, "deposit works");
        uint256 secondShares = _vault.balanceOf(_user) / 10;
        vm.prank(_user);
        assertGt(_vault.redeem(secondShares, _user, _user), 0, "second redeem works");
        uint256 nav = _refreshAndTotalAssets();
        assertGt(nav, 0);

        // execute works and the balance fuse reports the live value (no cache, record absent).
        _coreDeposit(1_000e6);
        assertTrue(_isPendingLive(), "a new action is a genuine new pending record");
        assertEq(_pendingNonce(), 3, "deposit, bridge, deposit");
    }

    function testDepositSettledThenCoreBalanceDropDoesNotReopenPending() public {
        _coreDeposit(100_000e6);
        _settle(2);
        assertFalse(_isPendingLive());

        // The first flow after settlement latches the record.
        vm.prank(_attacker);
        assertGt(_vault.deposit(1_000e6, _attacker), 0);
        assertFalse(_isPending(), "record cleared by the first user flow");

        // Core spot balance later drops (e.g. margin moved by another path): the effect is no longer observed.
        CoreSimulatorLib.forceSpotBalance(address(_vault), USDC_TOKEN, 95_000e8);
        assertFalse(_isPendingLive(), "no pending state without a record");
        uint256 redeemShares = _vault.balanceOf(_user) / 10;
        vm.prank(_user);
        assertGt(_vault.redeem(redeemShares, _user, _user), 0, "redeem works");
        _refreshAndTotalAssets();
    }

    function testSettledEventEmittedOnceByFirstUserFlowAfterSettlement() public {
        _coreDeposit(100_000e6);
        _settle(2);
        _sendAssetToEvm(50_000e8);
        CoreSimulatorLib.nextBlock();
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        uint256 nonce = _pendingNonce();
        assertEq(nonce, 2);

        vm.recordLogs();
        vm.prank(_attacker);
        _vault.deposit(1_000e6, _attacker);
        assertEq(_countSettled(vm.getRecordedLogs(), nonce), 1, "exactly one Settled(nonce) from the vault");

        vm.recordLogs();
        vm.prank(_attacker);
        _vault.deposit(1_000e6, _attacker);
        assertEq(_countSettled(vm.getRecordedLogs(), nonce), 0, "not emitted again");
        assertEq(_pendingNonce(), nonce, "nonce preserved");
    }

    function testSettledEventEmittedByFirstExecuteAndNextEnqueueGetsNextNonce() public {
        _coreDeposit(100_000e6);
        _settle(2);
        _sendAssetToEvm(50_000e8);
        CoreSimulatorLib.nextBlock();
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        uint256 nonce = _pendingNonce();

        vm.expectEmit(false, false, false, true, address(_vault));
        emit HyperCorePendingLib.HyperCoreActionSettled(nonce);
        _coreDeposit(1_000e6);

        assertEq(_pendingNonce(), nonce + 1, "next enqueue gets nonce + 1");
        assertTrue(_isPendingLive(), "the new deposit is pending");
    }

    function testMarginRecordIsClearedByNextHookRun() public {
        _coreDeposit(100_000e6);
        _settle(2);
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector, HyperCoreMarginFuseEnterData({usd6: 10_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        uint256 nonce = _pendingNonce();
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
        assertTrue(_isPending(), "time-settled record still stored");

        vm.recordLogs();
        vm.prank(_attacker);
        _vault.deposit(1_000e6, _attacker);
        assertEq(_countSettled(vm.getRecordedLogs(), nonce), 1, "TIMING-settled action ends with an event");
        assertFalse(_isPending(), "margin record cleared");
        assertEq(_pendingNonce(), nonce);
    }

    function _pendingNonce() internal view returns (uint256) {
        ReadResult memory r =
            _vault.read(address(_pendingReader), abi.encodeCall(HyperCorePendingReader.pendingState, ()));
        return abi.decode(r.data, (HyperCorePendingReader.PendingStateResult)).state.actionNonce;
    }

    function _expectedBalance() internal view returns (uint256) {
        ReadResult memory r =
            _vault.read(address(_pendingReader), abi.encodeCall(HyperCorePendingReader.pendingState, ()));
        return abi.decode(r.data, (HyperCorePendingReader.PendingStateResult)).state.expectedBalance;
    }

    function _countSettled(Vm.Log[] memory logs_, uint256 nonce_) internal view returns (uint256 count) {
        for (uint256 i; i < logs_.length; ++i) {
            if (
                logs_[i].emitter == address(_vault)
                    && logs_[i].topics[0] == HyperCorePendingLib.HyperCoreActionSettled.selector
                    && abi.decode(logs_[i].data, (uint256)) == nonce_
            ) ++count;
        }
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------
    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(address(_pendingReader), abi.encodeCall(HyperCorePendingReader.isActionPending, ()));
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
