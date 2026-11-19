// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {
    PlasmaVault,
    FuseAction,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {RealizeManagementFeeFuse} from "../../contracts/fuses/management_fee/RealizeManagementFeeFuse.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {DoNothingFuse} from "../fuses/DoNothingFuse.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";
import {PlasmaVaultCloneLib} from "../test_helpers/PlasmaVaultCloneLib.sol";

/// @notice Holds the value (USD, 18 decimals) that the test market reports. The balance fuse runs by delegatecall
///         in the vault, so the settable value has to live outside the vault storage.
contract MarketValueHolder {
    uint256 public value;

    function set(uint256 value_) external {
        value = value_;
    }
}

/// @notice Balance fuse of the test market: reports the value kept in the holder
contract HolderBalanceFuse {
    uint256 public immutable MARKET_ID;
    MarketValueHolder public immutable HOLDER;

    constructor(uint256 marketId_, MarketValueHolder holder_) {
        MARKET_ID = marketId_;
        HOLDER = holder_;
    }

    function balanceOf() external view returns (uint256) {
        return HOLDER.value();
    }
}

/// @title PlasmaVaultManagementFeePerformanceFeeTest
/// @notice IL-8870 (T09): the performance fee and its high-water mark are priced on the NET share price, the price
///         that counts the accrued management fee as virtual fee shares V. There is no loss gate (IL-9403): the fee
///         owed at the current net price is charged in every call, so collecting the management fee never changes
///         the performance fee decision.
/// @dev Notation: S = minted supply, V = virtual management fee shares, p = performance fee shares, G = gross total
///      assets, F = accrued management fee, off = share scale (100: 6 asset decimals + 2 offset), one = 10^8.
///      FeeManager stores HWM = floor(one * 1e12 * (G + 1) / (S + V + p + off)) (IL-8744; the 1e12 scale of the rate
///      and the HWM is IL-9601, `RATE_SHARES` below), and `_addPerformanceFee` passes it the supply S + V, so the HWM
///      is the net price right after the performance fee mint.
///
///      Fee share sizing. FeeManager sizes p on the price after its own mint: with f = fee * (rate - HWM0) and the
///      rate floored to price units, p = floor((S + V) * f / (10000 * rate - f)), so that p / (S + V + p) is
///      x = f / (10000 * rate), the fee as a part of the vault value (the rate floored to units of the 1e12 scale),
///      and the price after the mint is the rate
///      less fee * (rate - HWM0) / 10000. Shares priced before their own mint ((S + V) * x) are worth x / (1 + x).
///
///      Minted share of the fee shares (derived, not picked). After the mint the vault prices the net price with
///      the minted supply, so the virtual shares become V' = F (S + m + off) / (G - F + 1) for m minted shares
///      instead of V = F (S + off) / (G - F + 1). With k = F / (G - F + 1) the denominator of the price is
///      D_net = (S + m + off)(1 + k) and the denominator of the HWM is D_hwm = (S + off)(1 + k) + p. They are
///      equal for m = p / (1 + k) = p (S + off) / (S + V + off): the vault mints that share of p, rounded up
///      (`_minted`). The floors of V, V' and the ceiling of m keep D_hwm <= D_net <= D_hwm + 2, so the net price
///      after the mint is never above the HWM and at most the value of two share units below it (`_priceGapBound`;
///      before the 1e12 scale this was "the HWM or one price unit below it"). Minting all of p instead would leave
///      D_net = D_hwm + p k: the price below the HWM by HWM * p * F / (D_hwm * (G - F + 1)), paid by the minted
///      supply S, and a result for the shareholders that depends on whether the fee was collected first.
///
///      Tolerance when the gross assets change inside one call (T02 warning). A realization in the same execute
///      runs BEFORE the market refresh, so it prices F on the earlier G, while the branch without it prices F on
///      the final G. The branches then use S + V_A and S + V_B with V = floor(F (S + off) / (G - F + 1)). Because
///      the management fee is proportional to the gross assets (F = r G), V is about S r / (1 - r) and does not
///      depend on G to first order: dV = |V_A - V_B| is only the integer rounding of F (one asset unit is about
///      S / G shares). The tolerance below is nevertheless derived from the measured dV and not assumed to be
///      zero. dV moves the rate by rate * dV / (S + V + off) (asserted; in the 1e12 scale of IL-9601 this is no longer
///      below one rate unit, so the two branches see different rates). p = floor(SV * f / (10000 * rate - f)) with
///      the rate R proportional to 1 / (SV + off) has, as a function of SV = S + V, a slope between -a and a / (1 - a),
///      a = perfFee / 10000 (with t = HWM / R in [0, 1]: from a (1 - t) / (1 - a + a t) down to -a at t = 1), so
///      |dp| <= dV * a / (1 - a) + 1. The new HWM moves by at most HWM * (dV + |dp|) / D_min + 1 with D_min the
///      smaller denominator, and the net price after the call is that HWM or at most `_priceGapBound` below it.
///      The bound applies to the fee shares FeeManager returns
///      (p); the branch without the collection mints the share `_minted(p)` of them. Measured on this fixture
///      (shares have 8 decimals): dV = 40 and 10, |dp| = 1 and 0 (before the 1e12 scale the HWM and the net price
///      after were identical, a price unit was one asset unit per whole share).
contract PlasmaVaultManagementFeePerformanceFeeTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    /// @dev assets that sit in the test market from the start
    uint256 public constant MARKET_ASSETS = 100_000e6;
    /// @dev asset growth above the HWM, about 4.5% of the gross assets
    uint256 public constant GAIN = 50_000e6;
    uint256 public constant ACCRUAL_PERIOD = 90 days;
    /// @dev time until the pending fee is checkpointed in the B1 test
    uint256 public constant PENDING_PERIOD = 166 days;
    /// @dev market value (asset units) that sets the HWM in the B1 test, then the market falls back to MARKET_ASSETS
    uint256 public constant HIGH_MARKET = 200_000e6;
    /// @dev stale market value recorded in the call of the B1 test: slightly above HIGH_MARKET
    uint256 public constant STALE_GAIN_MARKET = 200_400e6;
    uint256 public constant MARKET_ID = 100;
    /// @dev one share in share units (8 decimals)
    uint256 public constant ONE_SHARE = 1e8;
    /// @dev FeeManager.HIGH_WATER_MARK_SCALE (IL-9601): the rate and the HWM are assets per share times 1e12
    uint256 public constant HWM_SCALE = 1e12;
    /// @dev shares whose value is the rate in the HWM unit
    uint256 public constant RATE_SHARES = ONE_SHARE * HWM_SCALE;
    /// @dev share scale multiplier: 10 ** (share decimals - asset decimals)
    uint256 public constant SHARE_SCALE = 100;
    /// @dev USD (18 decimals) per asset unit (6 decimals) at the price of 1 USD
    uint256 public constant WAD_PER_ASSET_UNIT = 1e12;

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    PlasmaVault public plasmaVault;
    MarketValueHolder public holder;
    DoNothingFuse public doNothingFuse;
    RealizeManagementFeeFuse public realizeFuse;
    FeeManager public feeManager;
    address public managementFeeAccount;
    address public performanceFeeAccount;
    uint256 public basePerfShares;

    /// @dev State read around one operation
    struct Outcome {
        uint256 perfShares;
        uint256 mgmtShares;
        uint128 hwm;
        uint256 supply;
        uint256 price;
        uint256 gross;
        uint256 fee;
        /// @dev value of the user's shares at the net price
        uint256 userAssets;
    }

    /// @dev State right before an operation
    struct Pre {
        uint256 supply;
        uint256 gross;
        uint256 fee;
        uint128 hwm;
    }

    function setUp() public {
        asset = new MockERC20Decimals("Mock USDC", "mUSDC", 6);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        PriceOracleMiddleware priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        address[] memory sources = new address[](1);
        /// @dev the feed reports 18 decimals: 1e18 = 1 USD per asset unit
        sources[0] = address(new FixedValuePriceFeed(1e18));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = _createAccessManager();
        WithdrawManager withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = PlasmaVaultCloneLib.newPlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: PERFORMANCE_FEE,
                    feeFactory: address(new FeeManagerFactory()),
                    iporDaoFeeRecipientAddress: address(98989898)
                }),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager),
                address(0)
            )
        );

        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager, address(withdrawManager));

        holder = new MarketValueHolder();
        doNothingFuse = new DoNothingFuse(MARKET_ID);
        realizeFuse = new RealizeManagementFeeFuse();

        address[] memory fuses = new address[](2);
        fuses[0] = address(doNothingFuse);
        fuses[1] = address(realizeFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(MARKET_ID, address(new HolderBalanceFuse(MARKET_ID, holder)));
        balanceFuses[1] = MarketBalanceFuseConfig(
            IporFusionMarkets.ZERO_BALANCE_MARKET,
            address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET))
        );

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            atomist,
            address(plasmaVault),
            fuses,
            balanceFuses,
            new MarketSubstratesConfig[](0)
        );

        managementFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeAccount;
        performanceFeeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        feeManager = FeeManager(FeeAccount(performanceFeeAccount).FEE_MANAGER());

        /// @dev the test grants the entries it calls to ALPHA (updateMarketsBalances) and ATOMIST (HWM reset)
        bytes4[] memory alphaSigs = new bytes4[](2);
        alphaSigs[0] = PlasmaVault.updateMarketsBalances.selector;
        alphaSigs[1] = PlasmaVault.realizeManagementFee.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), alphaSigs, Roles.ALPHA_ROLE);
        bytes4[] memory atomistSigs = new bytes4[](1);
        atomistSigs[0] = FeeManager.updateHighWaterMarkPerformanceFee.selector;
        accessManager.setTargetFunctionRole(address(feeManager), atomistSigs, Roles.ATOMIST_ROLE);

        asset.mint(user, USER_DEPOSIT);
        vm.startPrank(user);
        asset.approve(address(plasmaVault), type(uint256).max);
        plasmaVault.deposit(USER_DEPOSIT, user);
        vm.stopPrank();

        /// @dev the first refresh initializes the HWM to the price at G = deposit + market assets (no fee yet)
        holder.set(MARKET_ASSETS * WAD_PER_ASSET_UNIT);
        _updateMarkets();
        assertGt(_hwm(), 0, "setup: HWM initialized");
        assertEq(feeManager.HIGH_WATER_MARK_SCALE(), HWM_SCALE, "setup: the HWM unit is assets per share times 1e12");
        /// @dev creating the market assets is a gain over the HWM set at the deposit, so this refresh already
        ///      charged one performance fee; every test counts the performance fee shares minted after it
        basePerfShares = plasmaVault.balanceOf(performanceFeeAccount);
    }

    // ---------------------------------------------------------------------------------------------------------
    // 1. HWM is the net price after the mint
    // ---------------------------------------------------------------------------------------------------------

    /// @notice updateMarketsBalances with an accrued management fee and a market gain: the performance fee shares
    ///         and the HWM equal the net model (supply S + V, minted share of p), nothing is realized, and the net
    ///         price after the mint is the HWM (at most one price unit below it).
    function testShouldSetHighWaterMarkToNetPriceAfterMint_whenUpdateMarketsBalancesAndFeeAccrued() public {
        _accrue();
        Pre memory pre = _pre();
        holder.set((MARKET_ASSETS + GAIN) * WAD_PER_ASSET_UNIT);

        _updateMarkets();

        _assertNetModelAfterCall(pre);
    }

    /// @notice The same through execute([DoNothingFuse]), which refreshes the touched market
    function testShouldSetHighWaterMarkToNetPriceAfterMint_whenExecuteDoNothingAndFeeAccrued() public {
        _accrue();
        Pre memory pre = _pre();
        holder.set((MARKET_ASSETS + GAIN) * WAD_PER_ASSET_UNIT);

        vm.prank(alpha);
        plasmaVault.execute(_actions(false));

        _assertNetModelAfterCall(pre);
    }

    /// @notice Stress case for the minted share: a management fee accrued for 25 years at 2% is half of the gross
    ///         assets, so V is about as large as the minted supply, and the market grows 30 times. The minted share
    ///         m is then about half of p, and the share scale on both sides of the ratio moves it by whole share
    ///         units (p * V * scale / (S + V)^2 >= 1), so the test pins the ratio p * (S + scale) / (S + V + scale)
    ///         itself. The net price after the mint is still the HWM and the accrued fee is untouched.
    function testShouldMintShareOnMintedSupplyWithShareScale_whenAccruedFeeIsHalfOfGrossAssets() public {
        vm.warp(block.timestamp + 25 * 365 days);
        Pre memory pre = _pre();
        holder.set(30 * MARKET_ASSETS * WAD_PER_ASSET_UNIT);

        _updateMarkets();

        _assertNetModelAfterCall(pre);

        Outcome memory o = _outcome();
        assertEq(o.fee, o.gross / 2, "precondition: the accrued fee is half of the gross assets");
        (uint256 v, uint256 expectedPerf, ) = _model(pre.supply, o.gross, o.fee, pre.hwm);
        assertGt(
            o.perfShares,
            Math.mulDiv(expectedPerf, pre.supply, pre.supply + v, Math.Rounding.Ceil),
            "precondition: the ratio without the share scale gives fewer shares"
        );
        assertApproxEqAbs(o.perfShares, expectedPerf / 2, expectedPerf / 100, "about half of p is minted");
    }

    // ---------------------------------------------------------------------------------------------------------
    // 2. net rate <= HWM < rate from the minted supply: no performance fee
    // ---------------------------------------------------------------------------------------------------------

    /// @notice After a performance fee the HWM is the net price. A later call on unchanged assets sees the net
    ///         rate at or below it, so it charges nothing, although the rate priced on the minted supply alone
    ///         (the old basis) is above the HWM and would have charged a fee on every call.
    function testShouldChargeNoPerformanceFee_whenNetRateBelowHwmButMintedSupplyRateAbove() public {
        _accrue();
        holder.set((MARKET_ASSETS + GAIN) * WAD_PER_ASSET_UNIT);
        _updateMarkets();
        uint128 hwm = _hwm();
        uint256 perfSharesBefore = _perfShares();
        assertGt(perfSharesBefore, 0, "precondition: the first call charged a performance fee");

        vm.warp(block.timestamp + 1 days);

        uint256 netRate = plasmaVault.convertToAssets(RATE_SHARES);
        uint256 mintedSupplyRate = Math.mulDiv(
            RATE_SHARES,
            plasmaVault.totalAssets() + 1,
            plasmaVault.totalSupply() + SHARE_SCALE
        );
        assertLe(netRate, hwm, "precondition: net rate at or below the HWM");
        assertGt(mintedSupplyRate, hwm, "precondition: rate from the minted supply is above the HWM");

        _updateMarkets();
        vm.prank(alpha);
        plasmaVault.execute(_actions(false));

        assertEq(_perfShares(), perfSharesBefore, "no performance fee shares minted");
        assertEq(_hwm(), hwm, "HWM unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------
    // 3. the same execute with and without the fuse
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Gross assets do not change inside the call (the gain is idle assets already in the vault): the
    ///         HWM, the net price after the call and with it the value the user keeps are identical with and
    ///         without the collection. FeeManager returns the same fee shares p in both; with the collection all
    ///         of p is minted (V is minted supply and shares the dilution), without it the share of p that falls
    ///         on the minted supply (the virtual fee shares stay worth F).
    function testShouldChargeIdenticalPerformanceFee_whenExecuteWithAndWithoutFuseAndGrossUnchangedInCall() public {
        _accrue();
        asset.mint(address(plasmaVault), GAIN);
        Pre memory pre = _pre();
        (uint256 v, uint256 expectedPerf, uint128 expectedHwm) = _model(pre.supply, pre.gross, pre.fee, pre.hwm);
        assertGt(v, 0, "precondition: management fee accrued");

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, MARKET_ASSETS);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, MARKET_ASSETS);

        assertGt(a.perfShares, 0, "performance fee charged with the collection");
        assertEq(a.perfShares, expectedPerf, "with the collection: performance fee shares equal the net model");
        assertEq(
            b.perfShares,
            _minted(expectedPerf, pre.supply, v),
            "without the collection: the minted share of the net model"
        );
        assertLt(b.perfShares, a.perfShares, "without the collection fewer shares are minted");
        assertEq(a.hwm, expectedHwm, "with the collection: HWM equals the net model");
        assertEq(b.hwm, expectedHwm, "without the collection: HWM equals the net model");

        assertEq(a.mgmtShares, v, "the collection minted exactly the virtual fee shares");
        assertEq(b.mgmtShares, 0, "no collection without the fuse");
        assertEq(a.supply, pre.supply + v + a.perfShares, "supply with the collection");
        assertEq(b.supply, pre.supply + b.perfShares, "supply without the collection");

        assertEq(a.fee, 0, "nothing accrued right after the collection");
        assertEq(a.price, a.hwm, "net price at the HWM after the collection");
        assertLe(b.price, b.hwm, "without the collection the net price is not above the HWM");
        assertLe(b.hwm - b.price, _priceGapBound(b), "without the collection the net price is at the HWM");
        assertLe(a.price - b.price, _priceGapBound(b), "net price after: the same in both branches");
        assertApproxEqAbs(a.userAssets, b.userAssets, 2, "the user keeps the same value in both branches");
        assertGt(b.fee, 0, "without the collection the fee is still accrued");
    }

    /// @notice The same for any idle gain up to 10 times the vault and any accrual period up to 20 years (F up to 40%
    ///         of the gross assets): with and without the collection the decision and the HWM are identical, the net
    ///         price after the call is that HWM, and the user keeps the same value.
    function testFuzzShouldKeepUserValue_whenExecuteWithAndWithoutFuseAndGrossUnchangedInCall(
        uint256 gain_,
        uint256 period_
    ) public {
        gain_ = bound(gain_, 0, 100 * MARKET_ASSETS);
        period_ = bound(period_, 1 days, 20 * 365 days);
        vm.warp(block.timestamp + period_);
        asset.mint(address(plasmaVault), gain_);

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, MARKET_ASSETS);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, MARKET_ASSETS);

        assertEq(a.perfShares > 0, b.perfShares > 0, "the same decision in both branches");
        assertEq(a.hwm, b.hwm, "the same HWM in both branches");
        /// @dev `_gap` checks that the net price is not above the HWM, also when nothing was charged
        uint256 gapA = _gap(a);
        uint256 gapB = _gap(b);
        if (a.perfShares > 0) {
            assertLe(gapA, _priceGapBound(a), "with the collection: net price after the fee is the HWM");
            assertLe(gapB, _priceGapBound(b), "without the collection: net price after the fee is the HWM");
        }
        assertApproxEqAbs(a.userAssets, b.userAssets, 2, "the user keeps the same value in both branches");
    }

    /// @notice Gross assets change inside the call (market gain refreshed after the collection): the decision is
    ///         identical (a performance fee in both) and the amounts agree within the tolerance derived from the
    ///         different S + V (the collection priced F on the earlier G).
    function testShouldChargePerformanceFeeWithinTolerance_whenExecuteWithAndWithoutFuseAndGrossGainsInCall() public {
        _accrue();
        Pre memory pre = _pre();

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, MARKET_ASSETS + GAIN);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, MARKET_ASSETS + GAIN);

        assertGt(a.gross, pre.gross, "precondition: gross assets rose in the call");
        assertGt(a.perfShares, 0, "with the collection: a performance fee is charged");
        assertGt(b.perfShares, 0, "without the collection: a performance fee is charged");
        _assertBranchesWithinTolerance(pre, a, b);
    }

    // ---------------------------------------------------------------------------------------------------------
    // 4. the collection alone
    // ---------------------------------------------------------------------------------------------------------

    /// @notice realizeManagementFee() with the HWM equal to the current net price: the price does not move by a
    ///         single unit, so nothing is charged, and the HWM is not touched
    function testShouldNotRaisePriceOrChargePerformanceFee_whenFeeCollectedByMethod() public {
        _accrue();
        uint256 price = _setHwmToCurrentPrice();
        Pre memory pre = _pre();
        uint256 expectedShares = _feeShares(pre.fee, pre.supply, pre.gross);
        assertGt(expectedShares, 0, "precondition: a fee is accrued");

        vm.prank(alpha);
        uint256 minted = plasmaVault.realizeManagementFee();

        assertEq(minted, expectedShares, "minted the virtual fee shares");
        assertEq(plasmaVault.balanceOf(managementFeeAccount), minted, "fee account received the shares");
        assertEq(plasmaVault.convertToAssets(RATE_SHARES), price, "net price unchanged");
        assertEq(_perfShares(), 0, "no performance fee");
        assertEq(_hwm(), pre.hwm, "HWM unchanged");
    }

    /// @notice The same through the fuse in execute: _addPerformanceFee runs right after it, with the net rate
    ///         exactly at the HWM, and charges nothing
    function testShouldNotRaisePriceOrChargePerformanceFee_whenFeeCollectedByFuse() public {
        _accrue();
        uint256 price = _setHwmToCurrentPrice();
        Pre memory pre = _pre();
        uint256 expectedShares = _feeShares(pre.fee, pre.supply, pre.gross);
        assertGt(expectedShares, 0, "precondition: a fee is accrued");

        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction(address(realizeFuse), abi.encodeWithSignature("enter()"));
        vm.prank(alpha);
        plasmaVault.execute(calls);

        assertEq(plasmaVault.balanceOf(managementFeeAccount), expectedShares, "fee account received the shares");
        assertEq(plasmaVault.convertToAssets(RATE_SHARES), price, "net price unchanged");
        assertEq(_perfShares(), 0, "no performance fee");
        assertEq(_hwm(), price, "HWM unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------
    // 5. a call that lowers the assets still charges the fee owed (IL-9403), independently of the collection
    // ---------------------------------------------------------------------------------------------------------

    /// @notice G falls inside the call by less than the accrued fee F (the market loses delta < F) while the net
    ///         rate stays far above the HWM (idle gain). Without a loss gate (IL-9403) both branches, with and
    ///         without the collection, charge the performance fee owed at the net price, equal within the tolerance
    ///         of the different S + V.
    function testShouldChargePerformanceFeeInBothBranches_whenGrossFallsByLessThanAccruedFee() public {
        _accrue();
        asset.mint(address(plasmaVault), GAIN);
        Pre memory pre = _pre();
        uint256 loss = pre.fee / 2;
        assertGt(loss, 0, "precondition: a fee is accrued");

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, MARKET_ASSETS - loss);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, MARKET_ASSETS - loss);

        assertLt(a.gross, pre.gross, "gross fell (collection branch)");
        assertLt(b.gross, pre.gross, "gross fell (no collection branch)");
        assertEq(a.gross, b.gross, "same gross in both branches");

        assertGt(a.perfShares, 0, "performance fee charged (collection branch)");
        assertGt(b.perfShares, 0, "performance fee charged (no collection branch)");
        assertGt(a.mgmtShares, 0, "the collection branch really collected");
        _assertBranchesWithinTolerance(pre, a, b);
    }

    /// @notice Control: the same setup, gross rises inside the call instead of falling. Both branches charge a
    ///         non-zero performance fee, equal within the tolerance of the different S + V.
    function testShouldChargePerformanceFeeInBothBranches_whenGrossRisesByLessThanAccruedFee() public {
        _accrue();
        asset.mint(address(plasmaVault), GAIN);
        Pre memory pre = _pre();
        uint256 rise = pre.fee / 2;

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, MARKET_ASSETS + rise);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, MARKET_ASSETS + rise);

        assertGt(a.gross, pre.gross, "gross rose (collection branch)");
        assertGt(a.perfShares, 0, "performance fee charged (collection branch)");
        assertGt(b.perfShares, 0, "performance fee charged (no collection branch)");
        _assertBranchesWithinTolerance(pre, a, b);
    }

    /// @notice The former D-029 case, now without a loss gate (IL-9403). A full year of accrual at 2% with G a
    ///         multiple of 50 makes F = G / 50 exactly. A market loss of one unit lands on a floor step of that
    ///         accrual, so F falls by one as well and the net assets are equal before and after the call. The call
    ///         charges the performance fee on the donation gain at once, equal to an independent model of the
    ///         FeeManager on the net price, and a following call without a change charges nothing more.
    function testShouldChargePerformanceFeeInLossCall_whenOneUnitLossKeepsNetAssetsEqual() public {
        vm.warp(block.timestamp + 365 days);
        asset.mint(address(plasmaVault), GAIN);
        Pre memory pre = _pre();
        assertEq(pre.gross, USER_DEPOSIT + MARKET_ASSETS + GAIN, "precondition: gross before the loss");
        assertEq(pre.gross % 50, 0, "precondition: gross is a multiple of 50");
        assertEq(pre.fee, pre.gross / 50, "precondition: F = G / 50 after a year at 2%");

        uint256 fee1 = pre.fee - 1;
        uint256 v1 = _feeShares(fee1, pre.supply, pre.gross - 1);
        (uint256 expectedPerf, uint128 expectedHwm) = _perfModel(pre.supply + v1, pre.gross - 1, pre.hwm);
        expectedPerf = _minted(expectedPerf, pre.supply, v1);
        assertGt(expectedPerf, 0, "precondition: a performance fee is owed");
        assertGt(expectedHwm, pre.hwm, "precondition: the HWM rises");

        /// @dev E1: a market loss of one asset unit
        holder.set((MARKET_ASSETS - 1) * WAD_PER_ASSET_UNIT);
        _updateMarkets();
        Outcome memory e1 = _outcome();

        assertEq(e1.gross, pre.gross - 1, "precondition: gross fell by one unit");
        assertEq(e1.fee, fee1, "precondition: the accrual fell by one unit (floor step)");
        assertEq(e1.gross - e1.fee, pre.gross - pre.fee, "precondition: net assets equal before and after");

        assertEq(e1.perfShares, expectedPerf, "E1: the performance fee equals the independent model");
        assertEq(e1.hwm, expectedHwm, "E1: HWM equals the independent model");

        /// @dev E1b: the next call without a change charges nothing more
        _updateMarkets();
        Outcome memory e1b = _outcome();

        assertEq(e1b.gross, e1.gross, "precondition: no gross change in the next call");
        assertEq(e1b.perfShares, e1.perfShares, "E1b: no further performance fee");
        assertEq(e1b.hwm, e1.hwm, "E1b: HWM unchanged");
    }

    // ---------------------------------------------------------------------------------------------------------
    // 6. pending fee repricing when a market is revalued after the fuse (CR #2 / B1, characterization)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice Pins the effect that the D-026 rule (the fuse alone in its own top-level execute) avoids. A pending fee P is realized by the fuse
    ///         on the gross assets G_start, then the market refresh in the same call revalues a stale market to
    ///         G_end. The shares minted for P are worth P * (G_end + 1) / (G_start + 1) afterwards, not P, and the
    ///         supply S + V_A the performance fee sees differs from the supply S + V_B (V priced on G_end) of the
    ///         same execute without the fuse. With the HWM between the two branch rates the DECISION differs: no
    ///         performance fee with the fuse, a performance fee without it. D-012 (identical decision with and
    ///         without the fuse in one execute) holds only when the fuse runs alone (D-026) or no fee is pending; the
    ///         vault does not prevent the other case, the docs say so.
    function testShouldPinPendingFeeRepricing_whenFuseFirstAndMarketRevaluedInCall() public {
        /// @dev a pending fee through the production checkpoint (FeeManager, same rate), no accrual on top of it
        ///      (same block). Called directly: FeeManager.updateManagementFee reverts while the fee would mint a share
        ///      (IL-9431 gate); the fee account holds no shares here, so its harvest would change nothing.
        vm.warp(block.timestamp + PENDING_PERIOD);
        uint256 currentRate = PlasmaVaultGovernance(address(plasmaVault)).getManagementFeeData().feeInPercentage;
        vm.prank(address(feeManager));
        PlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(managementFeeAccount, currentRate);
        /// @dev the market first rises (a performance fee is charged and the HWM follows the net price), then falls
        ///      back: the HWM stays above the rate of the call's starting point
        holder.set(HIGH_MARKET * WAD_PER_ASSET_UNIT);
        _updateMarkets();
        holder.set(MARKET_ASSETS * WAD_PER_ASSET_UNIT);
        _updateMarkets();
        basePerfShares = plasmaVault.balanceOf(performanceFeeAccount);

        Pre memory pre = _pre();
        uint256 pending = _pending();
        assertEq(pre.fee, pending, "precondition: only the pending fee is accrued");
        assertGt(pending, 0, "precondition: pending fee");

        uint256 gEnd = pre.gross - MARKET_ASSETS + STALE_GAIN_MARKET;
        uint256 vA = _feeShares(pre.fee, pre.supply, pre.gross);
        uint256 vB = _feeShares(pre.fee, pre.supply, gEnd);
        _assertHwmBetweenBranchRates(pre, gEnd, vA, vB);

        uint256 snapshot = vm.snapshotState();
        Outcome memory a = _run(true, STALE_GAIN_MARKET);
        uint256 worthA = plasmaVault.convertToAssets(a.mgmtShares);
        vm.revertToState(snapshot);
        Outcome memory b = _run(false, STALE_GAIN_MARKET);

        assertEq(a.gross, gEnd, "gross assets after the revaluation");
        assertEq(b.gross, gEnd, "gross assets after the revaluation (no fuse)");

        /// @dev with the fuse: V_A minted on G_start, the fee account is worth P * (G_end + 1) / (G_start + 1)
        assertEq(a.mgmtShares, vA, "with the fuse: fee shares equal the D-002 model on G_start");
        assertApproxEqAbs(
            worthA,
            Math.mulDiv(pending, gEnd + 1, pre.gross + 1),
            1,
            "with the fuse: the fee account is worth P * (G_end + 1) / (G_start + 1)"
        );
        assertGt(
            plasmaVault.convertToAssets(a.mgmtShares),
            pending,
            "with the fuse: the fee account is worth more than P"
        );
        {
            (uint256 expectedPerfA, uint128 expectedHwmA) = _perfModel(pre.supply + vA, gEnd, pre.hwm);
            assertEq(expectedPerfA, 0, "model: no performance fee with the fuse");
            assertEq(a.perfShares, expectedPerfA, "with the fuse: no performance fee");
            assertEq(a.hwm, expectedHwmA, "with the fuse: HWM unchanged");
        }

        /// @dev without the fuse: nothing realized, the performance fee follows the model at S + V_B
        assertEq(b.mgmtShares, 0, "without the fuse: nothing realized");
        (uint256 expectedPerfB, uint128 expectedHwmB) = _perfModel(pre.supply + vB, gEnd, pre.hwm);
        assertGt(expectedPerfB, 0, "model: a performance fee without the fuse");
        assertEq(
            b.perfShares,
            _minted(expectedPerfB, pre.supply, vB),
            "without the fuse: the minted share of the model"
        );
        assertEq(b.hwm, expectedHwmB, "without the fuse: HWM equals the model");
        assertGt(b.hwm, pre.hwm, "without the fuse: the HWM rose");
    }

    // ---------------------------------------------------------------------------------------------------------
    // 7. exact settlement, stated in assets (no fee share formula)
    // ---------------------------------------------------------------------------------------------------------

    /// @notice A call that charges the performance fee while the management fee is only accrued. The user pays 10%
    ///         of the rise of its shares above the HWM at the net price, the performance fee account receives 10%
    ///         of that rise on the whole minted supply, and the accrued management fee is still worth F.
    function testShouldSettleExactly_whenPerformanceFeeChargedWithFeeAccrued() public {
        _accrue();

        (uint256 userFee, uint256 supplyFee) = _assertExactSettlement(MARKET_ASSETS + GAIN);

        assertGt(userFee, 0, "precondition: the user owes a performance fee");
        assertGt(supplyFee, userFee, "precondition: the minted supply is more than the user's shares");
    }

    /// @notice The same for any gain or loss of the market and any accrual period up to 20 years (F up to 40% of the
    ///         gross assets), including the calls that charge nothing
    function testFuzzShouldSettleExactly_whenPerformanceFeeChargedWithFeeAccrued(
        uint256 marketAssets_,
        uint256 period_
    ) public {
        marketAssets_ = bound(marketAssets_, 0, 100 * MARKET_ASSETS);
        period_ = bound(period_, 0, 20 * 365 days);
        vm.warp(block.timestamp + period_);

        _assertExactSettlement(marketAssets_);
    }

    /// @notice redeem realizes the management fee first and then charges the performance fee on a gain that sits
    ///         idle in the vault. The user (assets received plus the value of the shares left) pays the same 10% of
    ///         its gain, and the two fee accounts together hold the accrued management fee plus 10% of the gain of
    ///         the supply that existed before the call.
    function testShouldSettleExactly_whenRedeemRealizesFeeBeforePerformanceFee() public {
        _accrue();
        asset.mint(address(plasmaVault), GAIN);
        Pre memory pre = _pre();
        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 redeemed = userShares / 4;

        (uint256 userGain, uint256 supplyGain) = _gains(pre, userShares, pre.gross, pre.fee);
        uint256 userBefore = Math.mulDiv(userShares, pre.gross - pre.fee + 1, pre.supply + SHARE_SCALE);

        vm.prank(user);
        uint256 received = plasmaVault.redeem(redeemed, user, user);

        Outcome memory o = _outcome();
        assertEq(o.fee, 0, "the management fee was realized");
        assertGt(o.mgmtShares, 0, "the management fee account holds the fee shares");
        assertGt(o.perfShares, 0, "a performance fee was charged");
        /// @dev the redeem burns the user's shares after the fee mint (price = HWM then) and pays the assets rounded
        ///      down, so the price can only rise, by at most one asset unit over the remaining supply. In one asset
        ///      unit per share the floor hid it (the price was the HWM); in the 1e12 unit of IL-9601 it is visible.
        assertGe(o.price, o.hwm, "redeem: net price after is not below the HWM");
        assertLe(
            o.price - o.hwm,
            Math.mulDiv(RATE_SHARES, 1, o.supply + SHARE_SCALE, Math.Rounding.Ceil) + 1,
            "redeem: net price after is the HWM up to the payout rounding"
        );

        uint256 userFee = (userGain * PERFORMANCE_FEE) / 10000;
        assertGe(received + o.userAssets + 4, userBefore - userFee, "the user pays no more than 10% of its gain");
        assertApproxEqAbs(
            received + o.userAssets,
            userBefore - userFee,
            _feeOnOnePriceUnit(userShares) + 4,
            "the user pays 10% of its gain above the HWM"
        );
        assertApproxEqAbs(
            plasmaVault.convertToAssets(o.perfShares) + plasmaVault.convertToAssets(o.mgmtShares),
            pre.fee + (supplyGain * PERFORMANCE_FEE) / 10000,
            _feeOnOnePriceUnit(pre.supply) + 4,
            "the fee accounts hold the management fee plus 10% of the gain"
        );
    }

    // ---------------------------------------------------------------------------------------------------------
    // helpers
    // ---------------------------------------------------------------------------------------------------------

    /// @dev Refreshes the market at `marketAssets_` with the management fee accrued and checks what every party
    ///      holds afterwards, in assets. The expectations use only the net assets G - F, the HWM and the fee
    ///      percentage: the net price before the fee is (G - F + 1) / (S + off) per share unit.
    /// @return userFee 10% of the user's gain above the HWM, supplyFee the same on the whole minted supply
    function _assertExactSettlement(uint256 marketAssets_) internal returns (uint256 userFee, uint256 supplyFee) {
        Pre memory pre = _pre();
        uint256 userShares = plasmaVault.balanceOf(user);
        holder.set(marketAssets_ * WAD_PER_ASSET_UNIT);

        _updateMarkets();

        Outcome memory o = _outcome();
        (uint256 userGain, uint256 supplyGain) = _gains(pre, userShares, o.gross, o.fee);
        userFee = (userGain * PERFORMANCE_FEE) / 10000;
        supplyFee = (supplyGain * PERFORMANCE_FEE) / 10000;
        uint256 clampedFee = o.fee > o.gross ? o.gross : o.fee;
        uint256 userBefore = Math.mulDiv(userShares, o.gross - clampedFee + 1, pre.supply + SHARE_SCALE);

        /// @dev The rate is floored to price units (1e-12 of an asset unit per whole share since IL-9601), so the fee
        ///      on less than one price unit per whole share is not charged in this call; nothing else separates the
        ///      result from the expectation but a few units of rounding. The user never pays more than its 10%.
        assertGe(o.userAssets + 4, userBefore - userFee, "the user pays no more than 10% of its gain");
        assertApproxEqAbs(
            o.userAssets,
            userBefore - userFee,
            _feeOnOnePriceUnit(userShares) + 4,
            "the user pays 10% of its gain above the HWM"
        );
        assertApproxEqAbs(
            plasmaVault.convertToAssets(o.perfShares),
            supplyFee,
            _feeOnOnePriceUnit(pre.supply) + 4,
            "the performance fee account receives 10% of the gain of the minted supply"
        );
        assertEq(o.mgmtShares, 0, "the call did not realize the management fee");
        assertApproxEqAbs(
            Math.mulDiv(
                _feeShares(o.fee, o.supply, o.gross),
                o.gross + 1,
                o.supply + _feeShares(o.fee, o.supply, o.gross) + SHARE_SCALE
            ),
            clampedFee,
            1,
            "the accrued management fee is still worth F after the mint"
        );
        /// @dev `_gap` checks that the net price is not above the HWM, also when nothing was charged
        uint256 gap = _gap(o);
        if (o.perfShares > 0) {
            assertLe(gap, _priceGapBound(o), "net price after the fee is the HWM");
        }
    }

    /// @dev Rise of the value of `userShares_` and of the whole minted supply above the HWM, at the net price
    ///      (G - F + 1) / (S + off) before the performance fee; zero at or below the HWM
    function _gains(
        Pre memory pre_,
        uint256 userShares_,
        uint256 gross_,
        uint256 fee_
    ) internal pure returns (uint256 userGain, uint256 supplyGain) {
        uint256 net = gross_ - (fee_ > gross_ ? gross_ : fee_) + 1;
        uint256 userBefore = Math.mulDiv(userShares_, net, pre_.supply + SHARE_SCALE);
        uint256 userAtHwm = Math.mulDiv(userShares_, pre_.hwm, RATE_SHARES);
        uint256 supplyBefore = Math.mulDiv(pre_.supply, net, pre_.supply + SHARE_SCALE);
        uint256 supplyAtHwm = Math.mulDiv(pre_.supply, pre_.hwm, RATE_SHARES);
        userGain = userBefore > userAtHwm ? userBefore - userAtHwm : 0;
        supplyGain = supplyBefore > supplyAtHwm ? supplyBefore - supplyAtHwm : 0;
    }

    /// @dev Performance fee on one price unit of `shares_`, rounded up. A price unit is one unit of the HWM scale per
    ///      whole share, 1e-12 of an asset unit (IL-9601; one asset unit before).
    function _feeOnOnePriceUnit(uint256 shares_) internal pure returns (uint256) {
        return Math.mulDiv(shares_, PERFORMANCE_FEE, RATE_SHARES * 10000, Math.Rounding.Ceil);
    }

    /// @dev How far the net price after a performance fee mint may sit below the HWM, in the HWM unit: the pricing
    ///      supply after the mint is at most 2 share units above the HWM denominator D >= supply + off (see the
    ///      contract NatSpec), so HWM - price <= 2 * (HWM + 1) / D + 1 (the floors). Before the 1e12 scale (IL-9601)
    ///      this was one price unit; in asset value it is now 2 share units instead of one asset unit per share.
    function _priceGapBound(Outcome memory o_) internal pure returns (uint256) {
        return Math.mulDiv(uint256(o_.hwm) + 1, 2, o_.supply + SHARE_SCALE, Math.Rounding.Ceil) + 1;
    }

    /// @dev The HWM lies between the two branch rates: the call is a gain only without the fuse
    function _assertHwmBetweenBranchRates(Pre memory pre_, uint256 gEnd_, uint256 vA_, uint256 vB_) internal pure {
        assertGt(vA_, vB_, "precondition: the earlier, smaller G prices more shares for the same fee");
        uint256 rateA = Math.mulDiv(RATE_SHARES, gEnd_ + 1, pre_.supply + vA_ + SHARE_SCALE);
        uint256 rateB = Math.mulDiv(RATE_SHARES, gEnd_ + 1, pre_.supply + vB_ + SHARE_SCALE);
        assertLe(rateA, pre_.hwm, "precondition: rate with the fuse is not above the HWM");
        assertGt(rateB, pre_.hwm, "precondition: rate without the fuse is above the HWM");
    }

    /// @dev D-002, computed here independently of the vault (DA-12, D-019): F is clamped to G and the denominator is
    ///      G - F + 1, so a wrong vault formula cannot move the vault and this expectation together
    function _feeShares(uint256 fee_, uint256 supply_, uint256 gross_) internal pure returns (uint256) {
        if (fee_ == 0 || supply_ == 0 || gross_ == 0) {
            return 0;
        }
        uint256 clamped = fee_ > gross_ ? gross_ : fee_;
        return Math.mulDiv(clamped, supply_ + SHARE_SCALE, gross_ - clamped + 1);
    }

    /// @dev Model of the net performance fee. `sv_` is the supply seen by the fee (S + V).
    /// @return perfShares p, hwmAfter the stored HWM
    function _perfModel(
        uint256 sv_,
        uint256 gross_,
        uint128 hwm_
    ) internal pure returns (uint256 perfShares, uint128 hwmAfter) {
        uint256 rate = Math.mulDiv(RATE_SHARES, gross_ + 1, sv_ + SHARE_SCALE);
        if (rate <= hwm_) {
            return (0, hwm_);
        }
        uint256 feeValue = (rate - hwm_) * PERFORMANCE_FEE;
        perfShares = Math.mulDiv(sv_, feeValue, rate * 10000 - feeValue);
        hwmAfter = uint128(
            perfShares == 0 ? rate : Math.mulDiv(RATE_SHARES, gross_ + 1, sv_ + perfShares + SHARE_SCALE)
        );
    }

    function _model(
        uint256 supply_,
        uint256 gross_,
        uint256 fee_,
        uint128 hwm_
    ) internal pure returns (uint256 v, uint256 perfShares, uint128 hwmAfter) {
        v = _feeShares(fee_, supply_, gross_);
        (perfShares, hwmAfter) = _perfModel(supply_ + v, gross_, hwm_);
    }

    /// @dev Shares the vault mints out of the fee shares `perfShares_` that FeeManager returned for the supply
    ///      S + V (see the contract NatSpec): all of them when nothing is accrued, otherwise the share that falls
    ///      on the minted supply, rounded up. Computed here independently of the vault.
    function _minted(uint256 perfShares_, uint256 supply_, uint256 v_) internal pure returns (uint256) {
        if (v_ == 0) {
            return perfShares_;
        }
        return Math.mulDiv(perfShares_, supply_ + SHARE_SCALE, supply_ + v_ + SHARE_SCALE, Math.Rounding.Ceil);
    }

    /// @dev Checks the net model after a call that charged a performance fee without a collection
    function _assertNetModelAfterCall(Pre memory pre_) internal view {
        Outcome memory o = _outcome();
        (uint256 v, uint256 expectedPerf, uint128 expectedHwm) = _model(pre_.supply, o.gross, o.fee, pre_.hwm);

        assertGt(o.fee, 0, "precondition: management fee accrued");
        assertGt(v, 0, "precondition: virtual fee shares exist");
        assertGt(expectedPerf, 0, "precondition: the gain is above the HWM");
        assertEq(o.perfShares, _minted(expectedPerf, pre_.supply, v), "the minted share of the net model");
        assertLt(o.perfShares, expectedPerf, "fewer shares are minted than FeeManager returned");
        assertEq(o.hwm, expectedHwm, "HWM = (G + 1) * one * 1e12 / (S + V + p + off)");
        assertEq(o.mgmtShares, 0, "the call did not realize the management fee");
        assertEq(o.supply, pre_.supply + o.perfShares, "supply grew by the performance fee shares only");

        assertLe(o.price, o.hwm, "net price after the mint is not above the HWM");
        assertLe(o.hwm - o.price, _priceGapBound(o), "net price after the mint is the HWM");

        /// @dev the supply that prices the vault after the mint is the denominator of the HWM, up to the floors
        uint256 denominatorHwm = pre_.supply + v + expectedPerf + SHARE_SCALE;
        uint256 denominatorNet = o.supply + _feeShares(o.fee, o.supply, o.gross) + SHARE_SCALE;
        assertGe(denominatorNet, denominatorHwm, "pricing supply after the mint is not below the HWM denominator");
        assertLe(denominatorNet - denominatorHwm, 2, "pricing supply after the mint is the HWM denominator");
    }

    /// @dev Compares the branch with the collection (a) and without it (b) when G changed inside the call
    function _assertBranchesWithinTolerance(Pre memory pre_, Outcome memory a_, Outcome memory b_) internal {
        /// @dev a: the collection priced F on the gross assets before the call; b: the views price F on the final G
        uint256 vA = _feeShares(pre_.fee, pre_.supply, pre_.gross);
        uint256 vB = _feeShares(b_.fee, pre_.supply, b_.gross);
        assertEq(a_.mgmtShares, vA, "the collection minted V on the earlier gross assets");

        /// @dev a: V_A is minted supply, all of p is minted; b: V_B is virtual, the minted share of p
        uint256 perfB = _assertBranchModel(pre_, a_, vA, 0, "collection branch");
        perfB = _assertBranchModel(pre_, b_, vB, vB, "no collection branch");

        uint256 dV = _absDiff(vA, vB);

        {
            /// @dev the rates differ by about rate * dV / (S + V + off) (in one asset unit per share before IL-9601
            ///      they were the same floored rate)
            uint256 rateA = Math.mulDiv(RATE_SHARES, a_.gross + 1, pre_.supply + vA + SHARE_SCALE);
            uint256 rateB = Math.mulDiv(RATE_SHARES, b_.gross + 1, pre_.supply + vB + SHARE_SCALE);
            uint256 minSv = pre_.supply + (vA < vB ? vA : vB) + SHARE_SCALE;
            assertLe(
                _absDiff(rateA, rateB),
                Math.mulDiv(rateA > rateB ? rateA : rateB, dV, minSv, Math.Rounding.Ceil) +
                    Math.mulDiv(RATE_SHARES, _absDiff(a_.gross, b_.gross), minSv, Math.Rounding.Ceil) +
                    1,
                "precondition: the branch rates differ only by the dV repricing"
            );
        }
        uint256 dPerfBound = Math.mulDiv(dV, PERFORMANCE_FEE, 10000 - PERFORMANCE_FEE, Math.Rounding.Ceil) + 1;
        assertLe(_absDiff(a_.perfShares, perfB), dPerfBound, "fee shares from FeeManager within tolerance");

        uint256 denA = pre_.supply + vA + a_.perfShares + SHARE_SCALE;
        uint256 denB = pre_.supply + vB + perfB + SHARE_SCALE;
        uint256 hwmBound = Math.mulDiv(
            a_.hwm > b_.hwm ? a_.hwm : b_.hwm,
            dV + dPerfBound,
            denA < denB ? denA : denB,
            Math.Rounding.Ceil
        ) + 2;
        assertLe(_absDiff(a_.hwm, b_.hwm), hwmBound, "HWM within tolerance");
        assertLe(
            _absDiff(a_.price, b_.price),
            hwmBound + (_priceGapBound(a_) > _priceGapBound(b_) ? _priceGapBound(a_) : _priceGapBound(b_)),
            "net price after within tolerance"
        );
        assertLe(_gap(a_), _priceGapBound(a_), "collection branch: net price after is the HWM");
        assertLe(_gap(b_), _priceGapBound(b_), "no collection branch: net price after is the HWM");
    }

    /// @dev HWM minus the net price after the call; the price is never above the HWM
    function _gap(Outcome memory o_) internal pure returns (uint256) {
        assertLe(o_.price, o_.hwm, "net price after is not above the HWM");
        return o_.hwm - o_.price;
    }

    /// @dev One branch equals the net model at its own S + V. `virtual_` is the part of V that is not minted when
    ///      the performance fee is charged (0 after a collection, V without it).
    /// @return expectedPerf fee shares FeeManager returned in this branch (before the minted share is taken)
    function _assertBranchModel(
        Pre memory pre_,
        Outcome memory o_,
        uint256 v_,
        uint256 virtual_,
        string memory label_
    ) internal pure returns (uint256 expectedPerf) {
        uint128 expectedHwm;
        (expectedPerf, expectedHwm) = _perfModel(pre_.supply + v_, o_.gross, pre_.hwm);
        assertEq(
            o_.perfShares,
            _minted(expectedPerf, pre_.supply, virtual_),
            string.concat(label_, ": performance fee shares equal the net model")
        );
        assertEq(o_.hwm, expectedHwm, string.concat(label_, ": HWM equals the net model"));
    }

    function _absDiff(uint256 x_, uint256 y_) internal pure returns (uint256) {
        return x_ > y_ ? x_ - y_ : y_ - x_;
    }

    /// @dev Runs execute as ALPHA after setting the market value; the actions refresh the DoNothingFuse market
    function _run(bool withFuse_, uint256 marketAssets_) internal returns (Outcome memory) {
        holder.set(marketAssets_ * WAD_PER_ASSET_UNIT);
        vm.prank(alpha);
        plasmaVault.execute(_actions(withFuse_));
        return _outcome();
    }

    function _actions(bool withFuse_) internal view returns (FuseAction[] memory actions) {
        actions = new FuseAction[](withFuse_ ? 2 : 1);
        uint256 i;
        if (withFuse_) {
            actions[i++] = FuseAction(address(realizeFuse), abi.encodeWithSignature("enter()"));
        }
        actions[i] = FuseAction(address(doNothingFuse), abi.encodeWithSignature("enter((address))", address(asset)));
    }

    function _updateMarkets() internal {
        uint256[] memory markets = new uint256[](1);
        markets[0] = MARKET_ID;
        vm.prank(alpha);
        plasmaVault.updateMarketsBalances(markets);
    }

    function _accrue() internal {
        vm.warp(block.timestamp + ACCRUAL_PERIOD);
    }

    /// @dev Sets the HWM to the current net price (atomist) and returns that price
    function _setHwmToCurrentPrice() internal returns (uint256 price) {
        feeManager.updateHighWaterMarkPerformanceFee();
        price = plasmaVault.convertToAssets(RATE_SHARES);
        assertEq(_hwm(), price, "precondition: HWM at the current net price");
    }

    function _pre() internal view returns (Pre memory) {
        return
            Pre({
                supply: plasmaVault.totalSupply(),
                gross: plasmaVault.totalAssets(),
                fee: plasmaVault.getUnrealizedManagementFee(),
                hwm: _hwm()
            });
    }

    function _outcome() internal view returns (Outcome memory) {
        return
            Outcome({
                perfShares: _perfShares(),
                mgmtShares: plasmaVault.balanceOf(managementFeeAccount),
                hwm: _hwm(),
                supply: plasmaVault.totalSupply(),
                price: plasmaVault.convertToAssets(RATE_SHARES),
                gross: plasmaVault.totalAssets(),
                fee: plasmaVault.getUnrealizedManagementFee(),
                userAssets: plasmaVault.convertToAssets(plasmaVault.balanceOf(user))
            });
    }

    /// @dev Storage slot of the pending management fee (PlasmaVaultStorageLib.PENDING_MANAGEMENT_FEE_SLOT)
    function _pending() internal view returns (uint256) {
        return
            uint256(vm.load(address(plasmaVault), 0x612d50d27ffbb749a9804ec5bba7933bff2377ff69afba55e14b5cf7180bff00));
    }

    function _perfShares() internal view returns (uint256) {
        return plasmaVault.balanceOf(performanceFeeAccount) - basePerfShares;
    }

    function _hwm() internal view returns (uint128) {
        return feeManager.getPlasmaVaultHighWaterMarkPerformanceFee().highWaterMark;
    }

    function _createAccessManager() internal returns (IporFusionAccessManager) {
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        address[] memory alphas = new address[](1);
        alphas[0] = alpha;
        usersToRoles.alphas = alphas;
        return RoleLib.createAccessManager(usersToRoles, 0, vm);
    }
}
