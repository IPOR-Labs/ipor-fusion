// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {NavJumpFloorFixture} from "./HyperCoreNavJumpFloorFixture.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
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
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreCancelFuse,
    HyperCoreCancelFuseCancelByOidData
} from "../../../contracts/fuses/hypercore/HyperCoreCancelFuse.sol";
import {
    HyperCoreSendFuse,
    HyperCoreSendFuseSendAssetData
} from "../../../contracts/fuses/hypercore/HyperCoreSendFuse.sol";
import {HyperCorePendingReader} from "../../../contracts/fuses/hypercore/HyperCorePendingReader.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreAssetIdLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreAssetIdLib.sol";
import {HyperCoreSubstrateLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreSubstrateLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";

import {CoreSimulatorLib, coreWriter} from "./simulation/CoreSimulatorLib.sol";
import {HyperCore} from "./simulation/HyperCore.sol";
import {PrecompileLib} from "./simulation/src/PrecompileLib.sol";

/// @title HyperCoreUnattributedSettlementNoFreeInflowTest
/// @notice IL-9687 (Olympix 2026-11-06, L56 "Unattributed Settlement Effect"): proof that the reported attack does not
///         exist. The finding is right that the `EFFECT_CORE_SPOT` record of an EVM -> Core deposit settles on a plain
///         Core spot balance threshold (`HyperCorePendingLib.isEffectObserved`), so any inflow of the token can open
///         the gate before Core credits the deposit. Its attack needs a FREE inflow: an outsider filling the vault's
///         resting Core spot order (a bid for the token, or an ask paid in USDC) while the deposit is in transit, then
///         depositing at a NAV that is short of the in-transit amount. On the offline Core simulator this suite shows:
///         1. the vault can place no spot order at all: `HyperCoreOrderFuse` (the only order route) and
///            `HyperCoreCancelFuse` revert `HyperCoreInvalidPerpAsset` for every spot asset id (10_000 + spot index),
///            even when the id is granted as a PerpMarket; and a fill of a resting perp order moves perp margin and
///            position only, never the spot balance the predicate reads;
///         2. while the deposit is pending, every fuse action that could move value into Core spot (margin perp ->
///            spot, send-asset perp -> spot, a perp order) reverts `HyperCoreActionPending`, through the execute
///            pre-hook and through each fuse's own guard with that hook removed;
///         3. the only remaining inflow is a Core donation; it settles the record only when it covers the whole
///            in-transit amount, the live NAV after settlement is then not below the NAV with the in-transit amount
///            counted, and a donor that deposits D into a vault worth V gains at most D*X/(V+D) < X on the landing
///            credit X, so it loses money (fuzzed over V, X and D).
///         Everything passes on base 8692fbe5 too: this is a negative proof for a finding triaged "wrong", not a
///         regression test. Core lagging beyond `TransferTimeoutSeconds` is the separate residual risk accepted in
///         IL-8526/IL-9197 (README) and is out of scope here.
/// @dev Simulator modelling, on top of `HyperCoreEffectSettlementBase` (FusionFactory vault, both HyperCore pre-hooks):
///      - Core credit lag: the base fixture's `SimCoreDepositWallet` credits Core inside `depositFor`. Here USDC
///        (token 0) is re-pointed at `LaggingCoreDepositWallet`, which pulls the USDC at once (as the real wallet does)
///        but credits the vault's Core spot balance only when the test calls `land()`.
///      - A resting perp order fill: the simulator never rests perp orders, so the fill is modelled by Core executing
///        the vault's order directly (`HyperCore.executeRawAction` with the vault as sender), as matching would.
///      - A donation is a real Core `spotSend` sent by the donor through the CoreWriter and executed by
///        `CoreSimulatorLib.nextBlock()`, paid from the donor's own Core USDC.
///      - The NAV jump breaker is opened wide (`MaxNavJumpBps = type(uint64).max`) and the floor is an explicit 0
///        (`NavJumpFloorFixture.withFloor`, IL-9597), so the proof rests on the accounting alone, not on the breaker.
contract HyperCoreUnattributedSettlementNoFreeInflowTest is HyperCoreEffectSettlementBase {
    /// @dev First Core spot asset id (spot asset = 10_000 + spot index); ids below it are native perps.
    uint32 internal constant SPOT_ASSET_FIRST = 10_000;
    /// @dev First id above the spot asset space (the simulator routes 10_000..99_999 to its spot order book).
    uint32 internal constant SPOT_ASSET_END = 100_000;
    uint256 internal constant ACTIVATION_DEPOSIT = 100_000e6;
    uint256 internal constant IN_TRANSIT = 100_000e6;
    uint64 internal constant HYPE_MARK_PX = 400_000;
    /// @dev USDC: 6 EVM decimals, 8 Core wei decimals (`evmExtraWeiDecimals = -2`).
    uint256 internal constant USDC_EVM_TO_CORE_WEI = 100;

    /// @dev Values of one donation attack run, kept in memory to stay below the stack limit without via-ir.
    struct DonationAttack {
        uint256 inTransit;
        uint256 attackerDeposit;
        uint256 fairNav;
        uint256 fairShares;
        uint256 userValueBefore;
        uint256 shares;
        uint256 redeemed;
        uint256 gainBound;
    }

    address internal _attacker = makeAddr("ATTACKER");
    HyperCorePendingReader internal _pendingReader;
    LaggingCoreDepositWallet internal _laggingWallet;

    function setUp() public override {
        super.setUp();
        _pendingReader = new HyperCorePendingReader();

        _laggingWallet = new LaggingCoreDepositWallet(address(_usdc), USDC_TOKEN);
        PrecompileLib.TokenInfo memory usdcInfo = PrecompileLib.TokenInfo({
            name: "USDC",
            spots: new uint64[](0),
            deployerTradingFeeShare: 0,
            deployer: address(0),
            evmContract: address(_laggingWallet),
            szDecimals: 8,
            weiDecimals: 8,
            evmExtraWeiDecimals: -2
        });
        _hyperCore.registerTokenInfo(USDC_TOKEN, usdcInfo);

        _grantMarket55(new bytes32[](0));

        vm.prank(_atomist);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, _attacker, 0);

        // Activate the vault's Core account with a first deposit that lands at once (Core charges 1 USDC).
        _coreDeposit(ACTIVATION_DEPOSIT);
        _laggingWallet.land();
        _passWindow();
        _refreshAndTotalAssets();
        assertFalse(_isPending(), "activation deposit settled and latched");
        assertTrue(HyperCoreLib.coreUserExists(address(_vault)), "vault Core account activated");
    }

    // ------------------------------------------------------------------
    // 1. No spot order can exist, and a perp fill does not touch the spot balance
    // ------------------------------------------------------------------

    /// @notice The report's free inflow is a fill of the vault's resting spot order. The order fuse is the only route
    ///         to a Core order and rejects every spot asset id, even one granted as a PerpMarket substrate; the cancel
    ///         fuse rejects it too. A perp id with the same order data passes (the revert is specific to the id).
    function testFuzzOrderAndCancelFusesRejectEverySpotAssetId(uint256 spotIndex_) public {
        uint32 spotAsset = SPOT_ASSET_FIRST + uint32(bound(spotIndex_, 0, SPOT_ASSET_END - SPOT_ASSET_FIRST - 1));
        bytes32[] memory extra = new bytes32[](1);
        extra[0] = HyperCoreSubstrateLib.encodePerpMarket(spotAsset, 1_000_000e6, false);
        _grantMarket55(extra);

        bytes memory invalidAsset = abi.encodeWithSelector(
            HyperCoreAssetIdLib.HyperCoreInvalidPerpAsset.selector,
            spotAsset
        );

        // A resting bid for the token (pays the vault in the token) ...
        vm.expectRevert(invalidAsset);
        _vault.execute(_orderAction(spotAsset, true, HyperCoreLib.TIF_GTC));
        // ... or a resting ask paid in USDC: neither can be placed.
        vm.expectRevert(invalidAsset);
        _vault.execute(_orderAction(spotAsset, false, HyperCoreLib.TIF_GTC));
        // No spot order id can be managed either.
        vm.expectRevert(invalidAsset);
        _vault.execute(
            _one(
                address(_cancelFuse),
                abi.encodeWithSelector(
                    HyperCoreCancelFuse.enterCancelByOid.selector,
                    HyperCoreCancelFuseCancelByOidData({asset: spotAsset, oid: 1})
                )
            )
        );

        // Positive control: the same order on the granted native perp passes every check and is sent.
        _vault.execute(_orderAction(HYPE_PERP, true, HyperCoreLib.TIF_GTC));
        assertTrue(_isOrderInFlight(), "the perp order reached the CoreWriter");
    }

    /// @notice A resting perp order of the vault filled while a deposit is in transit settles into perp margin and
    ///         position only: the Core spot balance read by the effect predicate is unchanged, the record stays
    ///         pending and share-priced flows stay blocked until the real credit lands.
    function testPerpFillWhileDepositPendingLeavesSpotBalanceAndRecordUntouched() public {
        // Perp margin and a mark price, so a resting HYPE order can fill.
        _vault.execute(
            _one(
                address(_marginFuse),
                abi.encodeWithSelector(
                    HyperCoreMarginFuse.enter.selector,
                    HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
                )
            )
        );
        _settle(2);
        _refreshAndTotalAssets();
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 10);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, HYPE_MARK_PX);
        CoreSimulatorLib.setOraclePx(HYPE_PERP, HYPE_MARK_PX);

        uint64 pendingUntil = _pendingDepositPastWindow(IN_TRANSIT);
        uint64 spotBefore = _spotTotal();
        uint64 perpBefore = HyperCoreLib.withdrawable(address(_vault));
        assertLt(uint256(spotBefore), _expectedBalance(), "the credit has not landed yet");

        // Core matches the vault's resting sell order (sz 1e8 = 1.00 HYPE, limit 35 <= mark 40).
        _hyperCore.executeRawAction(
            address(_vault),
            ACTION_LIMIT_ORDER,
            abi.encode(HYPE_PERP, false, uint64(35e8), uint64(1e8), false, HyperCoreLib.TIF_GTC, CLOID_1)
        );

        assertLt(HyperCoreLib.position(address(_vault), HYPE_PERP).szi, 0, "the perp order filled");
        assertTrue(HyperCoreLib.withdrawable(address(_vault)) != perpBefore, "the fill moved perp margin");
        assertEq(_spotTotal(), spotBefore, "a perp fill does not change the Core spot balance");
        assertTrue(_isPendingLive(), "the record still waits for the Core credit");

        _mintAndApprove(_attacker, 1_000e6);
        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        _vault.deposit(1_000e6, _attacker);

        _laggingWallet.land();
        assertFalse(_isPendingLive(), "only the credit itself (or the timeout) opens the gate");
    }

    // ------------------------------------------------------------------
    // 2. No own action can move value into Core spot while the deposit is pending
    // ------------------------------------------------------------------

    /// @notice With the window and the L1-block gate already passed (only the Core credit is missing, the report's
    ///         precondition), every action that could raise the vault's Core spot balance reverts: first through the
    ///         `execute` pre-hook, then, with that hook removed, through each fuse's own pending guard.
    function testFuseActionsThatCouldMoveValueIntoSpotRevertWhileDepositPending() public {
        _vault.execute(
            _one(
                address(_marginFuse),
                abi.encodeWithSelector(
                    HyperCoreMarginFuse.enter.selector,
                    HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
                )
            )
        );
        _settle(2);
        _refreshAndTotalAssets();

        uint64 pendingUntil = _pendingDepositPastWindow(IN_TRANSIT);
        uint64 spotBefore = _spotTotal();
        bytes memory pendingErr = abi.encodeWithSelector(
            HyperCorePendingLib.HyperCoreActionPending.selector,
            pendingUntil
        );

        _expectEveryInflowActionReverts(pendingErr);

        // Defence in depth: without the execute pre-hook the fuses refuse on their own.
        _setExecutePreHook(address(0));
        assertEq(
            PlasmaVaultGovernance(address(_vault)).getPreHookImplementation(PlasmaVault.execute.selector),
            address(0),
            "execute pre-hook removed"
        );
        _expectEveryInflowActionReverts(pendingErr);

        assertEq(_spotTotal(), spotBefore, "nothing moved into Core spot");
        assertTrue(_isPendingLive(), "the deposit is still pending");
    }

    // ------------------------------------------------------------------
    // 3. A donation: settles only at the full in-transit amount, NAV is not short, the donor loses
    // ------------------------------------------------------------------

    /// @notice A Core donation one wei short of the in-transit amount does not settle the record; one more wei does.
    function testCoreDonationBelowInTransitAmountDoesNotSettle() public {
        uint64 pendingUntil = _pendingDepositPastWindow(IN_TRANSIT);
        uint256 missingWei = _expectedBalance() - uint256(_spotTotal());
        assertEq(missingWei, IN_TRANSIT * USDC_EVM_TO_CORE_WEI, "the record waits for exactly the in-transit amount");

        _donateOnCore(_attacker, uint64(missingWei - 1));
        assertTrue(_isPendingLive(), "a partial inflow does not settle the record");
        _mintAndApprove(_attacker, 1_000e6);
        vm.prank(_attacker);
        vm.expectRevert(abi.encodeWithSelector(HyperCorePendingLib.HyperCoreActionPending.selector, pendingUntil));
        _vault.deposit(1_000e6, _attacker);

        _donateOnCore(_attacker, 1);
        assertFalse(_isPendingLive(), "only an inflow covering the whole in-transit amount settles it");
    }

    /// @notice The report's scenario with its numbers (vault ~1,000,000, X = 100,000, attacker deposit 500,000): the
    ///         attacker recovers D*X/(V+D) ~ 33,333 of its own 100,000 donation and loses ~66,667.
    function testDonationAttackFromReportLosesMoneyForDonor() public {
        DonationAttack memory a = _runDonationAttack(IN_TRANSIT, 500_000e6);
        assertApproxEqAbs(a.redeemed - a.attackerDeposit, a.gainBound, 1e6, "attacker gets only its share of X");
        assertGt(a.inTransit - (a.redeemed - a.attackerDeposit), 66_000e6, "net loss of the donor ~66,667");
    }

    /// @notice Fuzz over the vault value V, the in-transit amount X and the attacker deposit D: the donor's gain on
    ///         the deposit is at most D*X/(V+D) < X, the NAV is never short and existing holders are not diluted.
    function testFuzzDonationThatSettlesPendingDepositCostsTheDonor(
        uint256 extraVaultDeposit_,
        uint256 inTransit_,
        uint256 attackerDeposit_
    ) public {
        uint256 extra = bound(extraVaultDeposit_, 0, 5_000_000e6);
        if (extra > 0) {
            _mintAndApprove(_secondUser, extra);
            vm.prank(_secondUser);
            _vault.deposit(extra, _secondUser);
        }
        // At most half of the EVM balance goes to Core, so the vault can pay the redemption from its EVM balance.
        uint256 inTransit = bound(inTransit_, 1e6, _usdc.balanceOf(address(_vault)) / 2);
        uint256 attackerDeposit = bound(attackerDeposit_, 1e6, 5_000_000e6);
        _runDonationAttack(inTransit, attackerDeposit);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    /// @dev ALPHA deposits `inTransit_` to Core while the credit lags; an outsider donates the missing amount on Core,
    ///      deposits D (its deposit latches the record and prices at the live NAV), the credit lands and it redeems.
    function _runDonationAttack(
        uint256 inTransit_,
        uint256 attackerDeposit_
    ) internal returns (DonationAttack memory a) {
        a.inTransit = inTransit_;
        a.attackerDeposit = attackerDeposit_;

        _pendingDepositPastWindow(inTransit_);
        // Fair values: NAV with the in-transit amount counted (`cachedValueWad` of market 55).
        a.fairNav = _vault.totalAssets();
        a.fairShares = _vault.previewDeposit(attackerDeposit_);
        a.userValueBefore = _vault.convertToAssets(_vault.balanceOf(_user));

        // The cheapest inflow that settles the record: a Core donation of exactly the in-transit amount.
        uint256 donationWei = _expectedBalance() - uint256(_spotTotal());
        assertEq(donationWei, inTransit_ * USDC_EVM_TO_CORE_WEI, "donation = in-transit amount (6 -> 8 decimals)");
        _donateOnCore(_attacker, uint64(donationWei));
        assertFalse(_isPendingLive(), "the donation stands in for the credit: the gate opens");

        _mintAndApprove(_attacker, attackerDeposit_);
        vm.prank(_attacker);
        a.shares = _vault.deposit(attackerDeposit_, _attacker);
        assertFalse(_isPending(), "the attacker's deposit latched the record");
        assertGe(_vault.totalAssets() - attackerDeposit_, a.fairNav, "live NAV after settlement is not short");
        assertLe(a.shares, a.fairShares, "no more shares than at the NAV with the in-transit amount counted");

        // Core finally credits the deposit; the attacker redeems everything.
        _laggingWallet.land();
        vm.prank(_attacker);
        a.redeemed = _vault.redeem(a.shares, _attacker, _attacker);

        a.gainBound = (attackerDeposit_ * inTransit_) / (a.fairNav + attackerDeposit_);
        assertLe(a.redeemed, attackerDeposit_ + a.gainBound, "gain on the deposit is at most D*X/(V+D)");
        assertLt(a.redeemed, attackerDeposit_ + inTransit_, "deposit + donation > redemption: the donor loses");
        assertGe(
            _vault.convertToAssets(_vault.balanceOf(_user)),
            a.userValueBefore,
            "existing holders are not diluted"
        );
    }

    /// @dev Margin perp -> spot, send-asset perp -> the vault's own spot, and a perp order (the only order route).
    function _expectEveryInflowActionReverts(bytes memory pendingErr_) internal {
        vm.expectRevert(pendingErr_);
        _vault.execute(
            _one(
                address(_marginFuse),
                abi.encodeWithSelector(
                    HyperCoreMarginFuse.enter.selector,
                    HyperCoreMarginFuseEnterData({usd6: 10_000e6, toPerp: false})
                )
            )
        );
        vm.expectRevert(pendingErr_);
        _vault.execute(
            _one(
                address(_sendFuse),
                abi.encodeWithSelector(
                    HyperCoreSendFuse.enterSendAsset.selector,
                    HyperCoreSendFuseSendAssetData({
                        destination: address(_vault),
                        sourceDex: HyperCoreLib.NATIVE_PERP_DEX,
                        destinationDex: HyperCoreLib.SPOT_DEX,
                        tokenIndex: USDC_TOKEN,
                        amountWei: 10_000e8
                    })
                )
            )
        );
        vm.expectRevert(pendingErr_);
        _vault.execute(_orderAction(HYPE_PERP, true, HyperCoreLib.TIF_IOC));
    }

    /// @dev Grants the market-55 set of the base fixture with the NAV jump breaker opened wide, plus `extra_`, and the
    ///      explicit zero `NavJumpFloorUsd6` (IL-9597) appended by `NavJumpFloorFixture.withFloor`.
    function _grantMarket55(bytes32[] memory extra_) internal {
        bytes32[] memory substrates = new bytes32[](9 + extra_.length);
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
        substrates[8] = HyperCoreSubstrateLib.encodeConfig(
            HyperCoreSubstrateLib.ConfigKey.MaxNavJumpBps,
            type(uint64).max
        );
        for (uint256 i; i < extra_.length; ++i) {
            substrates[9 + i] = extra_[i];
        }
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(
            MARKET_ID,
            NavJumpFloorFixture.withFloor(substrates)
        );
    }

    /// @dev Sends `amount_` EVM -> Core (the credit lags) and passes the window and the L1-block gate, so the record
    ///      waits only for the Core credit. Returns its `pendingUntil`.
    function _pendingDepositPastWindow(uint256 amount_) internal returns (uint64 pendingUntil) {
        _coreDeposit(amount_);
        pendingUntil = _pendingUntil();
        _passWindow();
        assertTrue(_isPendingLive(), "the deposit waits for its Core credit");
        assertLt(uint256(_spotTotal()), _expectedBalance(), "Core has not credited the deposit");
    }

    function _coreDeposit(uint256 amount_) internal {
        _vault.execute(
            _one(
                address(_depositFuse),
                abi.encodeWithSelector(
                    HyperCoreDepositFuse.enter.selector,
                    HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
                )
            )
        );
    }

    /// @dev The donor pays `coreWei_` from its own Core USDC with a `spotSend` to the vault, executed by Core.
    function _donateOnCore(address donor_, uint64 coreWei_) internal {
        CoreSimulatorLib.forceSpotBalance(donor_, USDC_TOKEN, coreWei_);
        vm.prank(donor_);
        coreWriter.sendRawAction(HyperCoreLib.encodeSpotSend(address(_vault), USDC_TOKEN, coreWei_));
        CoreSimulatorLib.nextBlock();
    }

    function _orderAction(uint32 asset_, bool isBuy_, uint8 tif_) internal view returns (FuseAction[] memory) {
        return
            _one(
                address(_orderFuse),
                abi.encodeWithSelector(
                    HyperCoreOrderFuse.enter.selector,
                    HyperCoreOrderFuseEnterData({
                        asset: asset_,
                        isBuy: isBuy_,
                        limitPx: 1e8,
                        sz: 1e8,
                        reduceOnly: false,
                        tif: tif_,
                        cloid: CLOID_2
                    })
                )
            );
    }

    function _one(address fuse_, bytes memory data_) internal pure returns (FuseAction[] memory actions) {
        actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
    }

    function _setExecutePreHook(address implementation_) internal {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVault.execute.selector;
        address[] memory implementations = new address[](1);
        implementations[0] = implementation_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        vm.prank(_atomist);
        PlasmaVaultGovernance(address(_vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    function _mintAndApprove(address account_, uint256 amount_) internal {
        _usdc.mint(account_, amount_);
        vm.prank(account_);
        _usdc.approve(address(_vault), amount_);
    }

    /// @dev Window 2 s + one Core L1 block (the simulator backs the L1 block number with `block.number`).
    function _passWindow() internal {
        vm.warp(block.timestamp + 3);
        vm.roll(block.number + 1);
    }

    function _spotTotal() internal view returns (uint64) {
        return HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total;
    }

    function _isPendingLive() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isActionPending, ())
        );
        return abi.decode(r.data, (bool));
    }

    function _isOrderInFlight() internal view returns (bool) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.isOrderInFlight, ())
        );
        return abi.decode(r.data, (bool));
    }

    function _expectedBalance() internal view returns (uint256) {
        ReadResult memory r = _vault.read(
            address(_pendingReader),
            abi.encodeCall(HyperCorePendingReader.pendingState, ())
        );
        return abi.decode(r.data, (HyperCorePendingReader.PendingStateResult)).state.expectedBalance;
    }

    function _pendingUntil() internal view returns (uint64) {
        return uint64(uint256(vm.load(address(_vault), PENDING_SLOT)));
    }
}

/// @dev CoreDepositWallet test double that models Core credit lag: `depositFor` pulls the USDC on the EVM side at once,
///      like the real wallet, but credits the recipient's Core spot balance only when the test calls `land()`, through
///      the same simulator entrypoint `SimCoreDepositWallet` uses.
contract LaggingCoreDepositWallet {
    HyperCore private constant HYPER_CORE = HyperCore(payable(0x9999999999999999999999999999999999999999));

    address public immutable token;
    uint64 public immutable tokenIndex;
    address public pendingRecipient;
    uint256 public pendingAmount;

    constructor(address token_, uint64 tokenIndex_) {
        token = token_;
        tokenIndex = tokenIndex_;
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function depositFor(address recipient_, uint256 amount_, uint32) external {
        IERC20(token).transferFrom(msg.sender, address(this), amount_);
        pendingRecipient = recipient_;
        pendingAmount += amount_;
    }

    /// @notice Core processes the queued deposit: credits the recipient's Core spot balance.
    function land() external {
        uint256 amount = pendingAmount;
        pendingAmount = 0;
        HYPER_CORE.executeTokenTransfer(address(0), tokenIndex, pendingRecipient, amount);
    }
}
