// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";

/// @title HyperCoreUsdcDepegValuationTest
/// @notice IL-8923 (Codex audit C-002; judge PoC C-005 with the assertions inverted): 0x80F `accountValue` is an
///         amount of USDC (the dex collateral token), so `HyperCoreValuationLib` prices perp equity with the same
///         USDC oracle price as the spot USDC leg. During a USDC depeg the NAV of a USDC vault, expressed in USDC,
///         therefore stays equal to the USDC the vault really holds: no redeemer is overpaid and a spot <-> perp
///         margin move does not create value (C-013).
/// @dev Uses the FusionFactory vault and the offline HyperCore simulator of `HyperCoreEffectSettlementBase` (USDC
///      underlying, `SpotToken(0, usdc)` granted, USDC feed at $1). The simulator keeps perp collateral as the
///      nominal USDC amount moved by the margin fuse, as HyperCore does. The depeg is a mocked feed answer of 0.90.
///
///      Rounding tolerance `USDC_ROUNDING_TOLERANCE` = 1 base unit of USDC (6 decimals), derived from the code path:
///      the oracle manager returns 18-decimal prices p, so the spot leg `spotWei * p / 1e8` and the perp leg
///      `accountValue * p / 1e6` are each rounded half up (<= 0.5 wei of USD WAD each, <= 1 wei together);
///      `PlasmaVaultMarketsLib` then divides by the underlying price (the same feed, p >= 0.9e18, so the error stays
///      below 1.2 wei at 18 decimals) and floors to 6 decimals. The booked market-55 value is thus the exact Core
///      USDC amount or one base unit below it, at any price; two such values differ by at most 1.
contract HyperCoreUsdcDepegValuationTest is HyperCoreEffectSettlementBase {
    uint256 private constant CORE_DEPOSIT = 500_000e6;
    uint64 private constant PERP_MARGIN_USD6 = 499_000e6;
    int256 private constant DEPEG_PRICE_1E8 = 0.9e8;
    uint256 private constant USDC_ROUNDING_TOLERANCE = 1;

    /// @dev C-005 inverted: with 499,000 USDC as perp equity and ~1,000 USDC on spot, a USDC feed at 0.90 leaves
    ///      market 55 and `totalAssets` (both in USDC) unchanged and equal to the USDC held on Core.
    function testUsdcDepegLeavesNavInUsdcUnchanged() public {
        _fundCoreAndMovePerpMargin(PERP_MARGIN_USD6);
        assertEq(_perpEquity(), int64(PERP_MARGIN_USD6), "setup: perp equity in USDC");
        uint256 totalAssetsAtPeg = _vault.totalAssets();
        uint256 marketAtPeg = _vault.totalAssetsInMarket(MARKET_ID);
        assertApproxEqAbs(marketAtPeg, _coreUsdc(), USDC_ROUNDING_TOLERANCE, "at $1 market 55 = USDC on Core");

        _depegUsdc();
        // The refresh reads the perp equity again and values it at the depegged price.
        vm.expectCall(address(HyperCoreLib.ACCOUNT_MARGIN_SUMMARY_PRECOMPILE), abi.encode(uint32(0), address(_vault)));
        uint256 totalAssetsInDepeg = _refreshAndTotalAssets();
        uint256 marketInDepeg = _vault.totalAssetsInMarket(MARKET_ID);

        assertApproxEqAbs(marketInDepeg, marketAtPeg, USDC_ROUNDING_TOLERANCE, "market 55 in USDC unchanged");
        assertApproxEqAbs(totalAssetsInDepeg, totalAssetsAtPeg, USDC_ROUNDING_TOLERANCE, "NAV in USDC unchanged");
        assertApproxEqAbs(marketInDepeg, _coreUsdc(), USDC_ROUNDING_TOLERANCE, "market 55 = USDC on Core");
    }

    /// @dev C-005 inverted: a 40% redeem during the depeg pays the redeemer's share of the USDC the vault really
    ///      holds (the PoC paid ~422,177 USDC against a fair ~400,000 before IL-8923).
    function testRedeemDuringUsdcDepegPaysFairShare() public {
        _fundCoreAndMovePerpMargin(PERP_MARGIN_USD6);

        uint256 realUsdcHeld = _usdc.balanceOf(address(_vault)) + _coreUsdc();
        uint256 shares = (_vault.balanceOf(_user) * 40) / 100;
        uint256 fairAssets = (realUsdcHeld * shares) / _vault.totalSupply();
        assertApproxEqRel(fairAssets, 400_000e6, 0.001e18, "setup: fair payout ~400k USDC");
        uint256 payoutAtPeg = _vault.previewRedeem(shares);

        _depegUsdc();
        uint256 balanceBefore = _usdc.balanceOf(_user);
        vm.prank(_user);
        uint256 received = _vault.redeem(shares, _user, _user);

        assertEq(_usdc.balanceOf(_user) - balanceBefore, received, "payout transferred");
        assertApproxEqAbs(received, payoutAtPeg, USDC_ROUNDING_TOLERANCE, "the depeg does not change the payout");
        // ERC-4626 virtual shares/assets (offset 2) move the payout by less than 1 base unit from the plain pro-rata
        // share here, so the payout is the fair share within the same tolerance and never above it.
        assertApproxEqAbs(received, fairAssets, USDC_ROUNDING_TOLERANCE, "redeemer receives the fair share");
        assertLe(received, fairAssets + USDC_ROUNDING_TOLERANCE, "redeemer is not overpaid");
        assertApproxEqAbs(
            _vault.totalAssetsInMarket(MARKET_ID),
            _coreUsdc(),
            USDC_ROUNDING_TOLERANCE,
            "market 55 still books the USDC held on Core"
        );
    }

    /// @dev C-013: with USDC at 0.90, ALPHA moves 400,000 USDC from spot to perp margin; after settlement and a
    ///      refresh market 55 and `totalAssets` are unchanged, because spot and perp USDC share one price.
    function testMarginMoveDuringUsdcDepegIsNavNeutral() public {
        _fundCoreAndMovePerpMargin(0);
        _depegUsdc();
        uint256 totalAssetsBefore = _refreshAndTotalAssets();
        uint256 marketBefore = _vault.totalAssetsInMarket(MARKET_ID);
        assertEq(_perpEquity(), 0, "setup: no perp equity before the move");

        _moveSpotToPerp(400_000e6);
        assertEq(_perpEquity(), int64(400_000e6), "setup: the move settled on Core");
        uint256 totalAssetsAfter = _refreshAndTotalAssets();

        assertApproxEqAbs(
            _vault.totalAssetsInMarket(MARKET_ID),
            marketBefore,
            USDC_ROUNDING_TOLERANCE,
            "market 55 unchanged by the margin move"
        );
        assertApproxEqAbs(totalAssetsAfter, totalAssetsBefore, USDC_ROUNDING_TOLERANCE, "NAV unchanged by the move");
        assertApproxEqAbs(marketBefore, _coreUsdc(), USDC_ROUNDING_TOLERANCE, "market 55 = USDC on Core");
    }

    /// @dev ALPHA deposits `CORE_DEPOSIT` USDC to Core (the simulator keeps the 1 USDC activation fee), settles and
    ///      refreshes market 55, then optionally moves `perpUsd6_` of spot USDC into native perp margin.
    function _fundCoreAndMovePerpMargin(uint64 perpUsd6_) private {
        _execute(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: CORE_DEPOSIT})
            )
        );
        _settle(2);
        _refreshAndTotalAssets();
        if (perpUsd6_ != 0) {
            _moveSpotToPerp(perpUsd6_);
            _refreshAndTotalAssets();
        }
    }

    function _moveSpotToPerp(uint64 usd6_) private {
        _execute(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: usd6_, toPerp: true})
            )
        );
        _settle(2);
    }

    /// @dev Mocks the vault's USDC/USD feed at 0.90 and checks that the vault oracle now reports it.
    function _depegUsdc() private {
        address feed = _priceManager.getSourceOfAssetPrice(address(_usdc));
        uint256 now_ = vm.getBlockTimestamp();
        vm.mockCall(
            feed,
            abi.encodeWithSignature("latestRoundData()"),
            abi.encode(uint80(1), DEPEG_PRICE_1E8, now_, now_, uint80(1))
        );
        (uint256 price, uint256 decimals) = _priceManager.getAssetPrice(address(_usdc));
        assertEq((price * 1e18) / 10 ** decimals, 0.9e18, "setup: vault oracle reports USDC at $0.90");
    }

    /// @dev USDC the vault holds on Core in 6 decimals: spot (Core wei, 8 decimals) plus native perp equity.
    function _coreUsdc() private view returns (uint256) {
        uint256 spotUsdc = uint256(HyperCoreLib.spotBalance(address(_vault), USDC_TOKEN).total) / 100;
        return spotUsdc + uint256(int256(_perpEquity()));
    }

    function _perpEquity() private view returns (int64) {
        return HyperCoreLib.accountMarginSummary(HyperCoreLib.NATIVE_PERP_DEX, address(_vault)).accountValue;
    }

    function _execute(address fuse_, bytes memory data_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(fuse_, data_);
        _vault.execute(actions);
    }
}
