// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    PlasmaVault,
    MarketBalanceFuseConfig,
    MarketSubstratesConfig,
    PlasmaVaultInitData,
    FuseAction
} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {FixedValuePriceFeed} from "../../contracts/price_oracle/price_feed/FixedValuePriceFeed.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeManagerFactory, FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {InstantWithdrawalFusesParamsStruct, PlasmaVaultLib} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporMath} from "../../contracts/libraries/math/IporMath.sol";
import {IFuseCommon} from "../../contracts/fuses/IFuseCommon.sol";
import {IMarketBalanceFuse} from "../../contracts/fuses/IMarketBalanceFuse.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MockERC20Decimals} from "../unitTest/fuses/term_finance/mocks/MockERC20Decimals.sol";

/// @notice External market that parks the vault's underlying; `slash` models a loss (bad debt, depeg, exit
///         slippage) that the vault's cached market balance has not seen yet
contract ResidualsMarket {
    using SafeERC20 for IERC20;

    address public immutable ASSET;
    mapping(address account => uint256 amount) public balances;

    constructor(address asset_) {
        ASSET = asset_;
    }

    function supply(uint256 amount_) external {
        IERC20(ASSET).safeTransferFrom(msg.sender, address(this), amount_);
        balances[msg.sender] += amount_;
    }

    function withdraw(uint256 amount_) external {
        balances[msg.sender] -= amount_;
        IERC20(ASSET).safeTransfer(msg.sender, amount_);
    }

    function balanceOf(address account_) external view returns (uint256) {
        return balances[account_];
    }

    function slash(address account_, uint256 amount_) external {
        balances[account_] -= amount_;
    }
}

/// @notice Supply and instant withdrawal fuse for ResidualsMarket (delegatecalled by the vault)
contract ResidualsSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    function enter(uint256 amount_) external {
        address underlying = IERC4626(address(this)).asset();
        IERC20(underlying).forceApprove(MARKET, amount_);
        ResidualsMarket(MARKET).supply(amount_);
        IERC20(underlying).forceApprove(MARKET, 0);
    }

    /// @param params_ [0] amount to withdraw (set by the vault)
    function instantWithdraw(bytes32[] calldata params_) external {
        uint256 amount = uint256(params_[0]);
        uint256 available = ResidualsMarket(MARKET).balanceOf(address(this));
        if (amount > available) {
            amount = available;
        }
        if (amount > 0) {
            ResidualsMarket(MARKET).withdraw(amount);
        }
    }
}

/// @notice Balance fuse for ResidualsMarket (USD, 18 decimals)
contract ResidualsBalanceFuse is IMarketBalanceFuse {
    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable MARKET;

    constructor(uint256 marketId_, address market_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        MARKET = market_;
    }

    function balanceOf() external view override returns (uint256) {
        uint256 amount = ResidualsMarket(MARKET).balanceOf(address(this));
        if (amount == 0) {
            return 0;
        }
        address underlying = IERC4626(address(this)).asset();
        (uint256 price, uint256 priceDecimals) = IPriceOracleMiddleware(PlasmaVaultLib.getPriceOracleMiddleware())
            .getAssetPrice(underlying);
        return IporMath.convertToWad(amount * price, IERC20Metadata(underlying).decimals() + priceDecimals);
    }
}

/// @title PlasmaVaultPreviewResidualsTest
/// @notice Pins two documented residuals of maxWithdraw, previewRedeem and previewWithdraw (IL-8493, review item
///         B-57). These tests PASS on the current code and DOCUMENT its behaviour; they are not bug reproductions.
///         The views simulate only the pending management fee (IL-8319/IL-8343, see
///         PlasmaVaultManagementFeeMaxPreviewTest), while withdraw and redeem do more before they check the limit
///         and price the call. The residuals were accepted as known limitations in IL-8489 and are documented in
///         the NatSpec of PlasmaVault.maxWithdraw, previewRedeem and previewWithdraw:
///         1. Performance fee. withdraw and redeem crystallize a pending performance fee (_addPerformanceFee,
///            rate above the high-water mark) first, so the views overestimate what the holder gets (and
///            underestimate the shares withdraw burns) by the holder's pro-rata share of that fee.
///         2. Stale market cache. The views price the cached market balances, withdraw and redeem refresh the
///            markets they pull from, so a market loss since the last balance update makes the views
///            over-promise by the holder's pro-rata share of the loss.
///         Every test asserts that the gap exists (> 0) and that it is bounded by that pro-rata share, derived
///         on-chain in the same state. If the views ever simulate the performance fee or the refresh (IL-8489
///         option (a)), these tests must be updated: the gaps close and the assertions on them turn around.
contract PlasmaVaultPreviewResidualsTest is Test {
    address public atomist = address(this);
    address public alpha = address(0x1);
    address public user = address(0xA11CE);
    address public other = address(0xB0B);

    /// @dev 2% per year, FeeManager percentages use 2 decimals (10000 = 100%)
    uint256 public constant MANAGEMENT_FEE = 200;
    /// @dev 10%
    uint256 public constant PERFORMANCE_FEE = 1000;
    /// @dev 1% in WAD
    uint256 public constant WITHDRAW_FEE = 1e16;
    uint256 public constant USER_DEPOSIT = 1_000_000e6;
    uint256 public constant VESTED_REWARDS = 20_000e6;
    uint256 public constant VESTING_TIME = 30 days;
    uint256 public constant MARKET_LOSS = 20_000e6;
    uint256 public constant MARKET_ID = 999_998;
    /// @dev the tiny exit another holder uses to crystallize the performance fee
    uint256 public constant CRYSTALLIZER_ASSETS = 1e6;
    /// @dev Rounding slack of the derived bounds, in the unit of the bounded quantity (asset wei or share units).
    ///      A bound chains a floor in convertToAssets(feeShares), a floor in the pro-rata mulDiv and the floors of
    ///      the two views it is compared with, that is at most 1 unit each, and the tiny crystallizing exit moves
    ///      the rate by well under one unit at this scale (1 share unit is 0.01 asset wei).
    uint256 public constant ROUNDING_SLACK = 4;

    bytes4 internal constant EXCEEDED_MAX_WITHDRAW =
        bytes4(keccak256("ERC4626ExceededMaxWithdraw(address,uint256,uint256)"));

    MockERC20Decimals public asset;
    UsersToRoles public usersToRoles;
    IporFusionAccessManager public accessManager;
    WithdrawManager public withdrawManager;
    PlasmaVault public plasmaVault;
    RewardsClaimManager public rewardsClaimManager;
    ResidualsMarket public market;
    ResidualsSupplyFuse public supplyFuse;

    /// @dev What crystallizing the pending performance fee mints and what it is measured against
    struct CrystallizedFee {
        /// @dev performance fee shares minted
        uint256 feeShares;
        /// @dev assets those shares are worth after the mint
        uint256 feeAssets;
        /// @dev total supply the fee was minted against: after the management fee realization, before the mint
        uint256 baseSupply;
    }

    // ---------------------------------------------------------------------------------------------
    // Residual 1: pending performance fee
    // ---------------------------------------------------------------------------------------------

    /// @dev Trigger: rewards vesting. withdraw(maxWithdraw) reverts and the enforced limit is lower by the holder's
    ///      pro-rata share of the pending performance fee
    function testShouldOverestimateMaxWithdraw_whenPerformanceFeePendingFromVestingRewards() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupVestingRewardsScenario();

        uint256 userShares = plasmaVault.balanceOf(user);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        CrystallizedFee memory fee = _crystallizedFeeByAnotherHolder();

        uint256 enforced = _enforcedWithdrawLimit(user, maxAssets);

        uint256 gap = maxAssets - enforced;
        uint256 bound = Math.mulDiv(fee.feeAssets, userShares, fee.baseSupply) + ROUNDING_SLACK;
        assertGt(gap, 0, "maxWithdraw overestimates the in-call limit");
        assertLe(gap, bound, "gap is at most the holder's share of the pending performance fee");
    }

    /// @dev Trigger: the withdraw fee burn of an earlier exit lifts the rate above the high-water mark. The withdraw
    ///      fee branch of maxWithdraw prices the holder at shares * (1 - fee) (IL-8751)
    function testShouldOverestimateMaxWithdraw_whenPerformanceFeePendingFromWithdrawFeeBurn() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupWithdrawFeeBurnScenario();

        uint256 effectiveShares = Math.mulDiv(plasmaVault.balanceOf(user), 1e18 - WITHDRAW_FEE, 1e18);
        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        CrystallizedFee memory fee = _crystallizedFeeByAnotherHolder();

        uint256 enforced = _enforcedWithdrawLimit(user, maxAssets);

        uint256 gap = maxAssets - enforced;
        uint256 bound = Math.mulDiv(fee.feeAssets, effectiveShares, fee.baseSupply) + ROUNDING_SLACK;
        assertGt(gap, 0, "maxWithdraw overestimates the in-call limit");
        assertLe(gap, bound, "gap is at most the holder's share of the pending performance fee");
    }

    /// @dev Once another holder crystallized the fee in the same block nothing is pending any more, so maxWithdraw
    ///      equals the in-call limit exactly and withdraw(maxWithdraw) succeeds
    function testShouldWithdrawMaxWithdraw_whenAnotherHolderCrystallizedPerformanceFeeInSameBlock() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupVestingRewardsScenario();

        uint256 maxBefore = plasmaVault.maxWithdraw(user);
        CrystallizedFee memory fee = _crystallizedFeeByAnotherHolder();
        assertGt(fee.feeShares, 0, "precondition: a performance fee was pending");

        vm.prank(other);
        plasmaVault.withdraw(CRYSTALLIZER_ASSETS, other, other);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        assertLt(maxAssets, maxBefore, "the crystallization lowered maxWithdraw to the real limit");
        assertEq(_enforcedWithdrawLimit(user, maxAssets), maxAssets, "maxWithdraw equals the in-call limit");

        uint256 balanceBefore = asset.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);
        assertEq(asset.balanceOf(user) - balanceBefore, maxAssets, "user received maxWithdraw");
    }

    /// @dev Trigger: rewards vesting. redeem pays less than previewRedeem by the holder's pro-rata share
    function testShouldOverestimatePreviewRedeem_whenPerformanceFeePendingFromVestingRewards() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupVestingRewardsScenario();

        _assertPreviewRedeemOverestimates(plasmaVault.balanceOf(user) / 2, 0);
    }

    /// @dev Trigger: withdraw fee burn, with the withdraw fee branch of previewRedeem
    function testShouldOverestimatePreviewRedeem_whenPerformanceFeePendingFromWithdrawFeeBurn() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupWithdrawFeeBurnScenario();

        _assertPreviewRedeemOverestimates(plasmaVault.balanceOf(user) / 2, WITHDRAW_FEE);
    }

    /// @dev Trigger: rewards vesting. withdraw burns more shares than previewWithdraw by the holder's pro-rata share
    function testShouldUnderestimatePreviewWithdraw_whenPerformanceFeePendingFromVestingRewards() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupVestingRewardsScenario();

        _assertPreviewWithdrawUnderestimates(USER_DEPOSIT / 2);
    }

    /// @dev Trigger: withdraw fee burn, with the withdraw fee branch of previewWithdraw
    function testShouldUnderestimatePreviewWithdraw_whenPerformanceFeePendingFromWithdrawFeeBurn() public {
        _deploy(PERFORMANCE_FEE, false);
        _setupWithdrawFeeBurnScenario();

        _assertPreviewWithdrawUnderestimates(USER_DEPOSIT / 4);
    }

    /// @dev Control: the same vesting scenario with performance fee 0. Nothing is pending, so the previews bound the
    ///      actuals and withdraw(maxWithdraw) succeeds
    function testShouldHonourPreviewsAndMaxWithdraw_whenPerformanceFeeIsZero() public {
        _deploy(0, false);
        _setupVestingRewardsScenario();

        uint256 shares = plasmaVault.balanceOf(user) / 2;
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);
        assertGe(paid, previewAssets, "previewRedeem <= redeem");
        vm.revertToState(snapshot);

        uint256 assets = USER_DEPOSIT / 2;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        uint256 sharesBefore = plasmaVault.balanceOf(user);
        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);
        assertLe(sharesBefore - plasmaVault.balanceOf(user), previewShares, "previewWithdraw >= burned");
        vm.revertToState(snapshot);

        uint256 maxAssets = plasmaVault.maxWithdraw(user);
        vm.prank(user);
        plasmaVault.withdraw(maxAssets, user, user);
        assertEq(asset.balanceOf(user), maxAssets, "user received maxWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // Residual 2: stale market cache
    // ---------------------------------------------------------------------------------------------

    /// @dev The vault is fully allocated to the market and the market lost 1% after the last balance update.
    ///      previewRedeem prices the cached balance, redeem refreshes it, so redeem pays less by the holder's
    ///      pro-rata share of the loss
    function testShouldOverestimatePreviewRedeem_whenMarketLossNotYetCached() public {
        _setupStaleMarketScenario();

        uint256 shares = plasmaVault.balanceOf(user);
        uint256 baseSupply = _supplyAfterManagementFee();
        uint256 previewAssets = plasmaVault.previewRedeem(shares);

        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);

        uint256 gap = previewAssets - paid;
        uint256 bound = Math.mulDiv(MARKET_LOSS, shares, baseSupply) + ROUNDING_SLACK;
        assertGt(previewAssets, paid, "previewRedeem overestimates redeem");
        assertGt(gap, 0, "gap exists");
        assertLe(gap, bound, "gap is at most the holder's share of the market loss");
    }

    /// @dev Same state on the withdraw side: withdraw burns more shares than previewWithdraw
    function testShouldUnderestimatePreviewWithdraw_whenMarketLossNotYetCached() public {
        _setupStaleMarketScenario();

        uint256 assets = USER_DEPOSIT / 2;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        uint256 cachedTotalAssets = plasmaVault.totalAssets();
        uint256 sharesBefore = plasmaVault.balanceOf(user);

        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);
        uint256 burned = sharesBefore - plasmaVault.balanceOf(user);

        /// @dev the loss lowers the assets per share from A to A - L, so the shares burned for the same assets rise
        ///      by the factor A / (A - L), that is by L / (A - L) of previewShares
        uint256 gap = burned - previewShares;
        uint256 bound = Math.mulDiv(previewShares, MARKET_LOSS, cachedTotalAssets - MARKET_LOSS) + ROUNDING_SLACK;
        assertGt(burned, previewShares, "withdraw burns more than previewWithdraw");
        assertGt(gap, 0, "gap exists");
        assertLe(gap, bound, "gap is at most the shares the loss adds to the price");
    }

    /// @dev After updateMarketsBalances the cache is fresh and the previews hold again
    function testShouldHonourPreviews_whenMarketBalancesUpdatedAfterLoss() public {
        _setupStaleMarketScenario();

        uint256 previewBefore = plasmaVault.previewRedeem(plasmaVault.balanceOf(user));

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_ID;
        vm.prank(alpha);
        plasmaVault.updateMarketsBalances(marketIds);

        uint256 shares = plasmaVault.balanceOf(user);
        uint256 previewAssets = plasmaVault.previewRedeem(shares);
        assertLt(previewAssets, previewBefore, "the refresh lowered the preview by the loss");

        uint256 snapshot = vm.snapshotState();
        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares, user, user);
        assertGe(paid, previewAssets, "previewRedeem <= redeem");
        assertLe(paid - previewAssets, 1, "redeem pays the preview");
        vm.revertToState(snapshot);

        uint256 assets = USER_DEPOSIT / 2;
        uint256 previewShares = plasmaVault.previewWithdraw(assets);
        vm.prank(user);
        plasmaVault.withdraw(assets, user, user);
        assertEq(plasmaVault.balanceOf(user), shares - previewShares, "withdraw burns previewWithdraw");
    }

    // ---------------------------------------------------------------------------------------------
    // Assertions and measurements
    // ---------------------------------------------------------------------------------------------

    function _assertPreviewRedeemOverestimates(uint256 shares_, uint256 withdrawFee_) internal {
        /// @dev the withdraw fee shares are burned without payout, so only the rest is priced
        uint256 pricedShares = Math.mulDiv(shares_, 1e18 - withdrawFee_, 1e18);
        uint256 previewAssets = plasmaVault.previewRedeem(shares_);
        CrystallizedFee memory fee = _crystallizedFeeByAnotherHolder();

        vm.prank(user);
        uint256 paid = plasmaVault.redeem(shares_, user, user);

        uint256 gap = previewAssets - paid;
        uint256 bound = Math.mulDiv(fee.feeAssets, pricedShares, fee.baseSupply) + ROUNDING_SLACK;
        assertGt(previewAssets, paid, "previewRedeem overestimates redeem");
        assertGt(gap, 0, "gap exists");
        assertLe(gap, bound, "gap is at most the holder's share of the pending performance fee");
    }

    function _assertPreviewWithdrawUnderestimates(uint256 assets_) internal {
        uint256 previewShares = plasmaVault.previewWithdraw(assets_);
        CrystallizedFee memory fee = _crystallizedFeeByAnotherHolder();
        uint256 sharesBefore = plasmaVault.balanceOf(user);

        vm.prank(user);
        plasmaVault.withdraw(assets_, user, user);
        uint256 burned = sharesBefore - plasmaVault.balanceOf(user);

        /// @dev the fee dilutes every holder by feeShares / baseSupply, so the shares needed for the same assets
        ///      rise by that fraction of previewShares
        uint256 gap = burned - previewShares;
        uint256 bound = Math.mulDiv(previewShares, fee.feeShares, fee.baseSupply) + ROUNDING_SLACK;
        assertGt(burned, previewShares, "withdraw burns more than previewWithdraw");
        assertGt(gap, 0, "gap exists");
        assertLe(gap, bound, "gap is at most the holder's share of the pending performance fee");
    }

    /// @dev Lets another holder crystallize the pending fees with a tiny exit in a snapshot and measures the
    ///      performance fee minted. The state is restored, so the caller sees the pending state again.
    function _crystallizedFeeByAnotherHolder() internal returns (CrystallizedFee memory fee) {
        address feeAccount = PlasmaVaultGovernance(address(plasmaVault)).getPerformanceFeeData().feeAccount;
        uint256 snapshot = vm.snapshotState();

        uint256 feeSharesBefore = plasmaVault.balanceOf(feeAccount);
        uint256 otherSharesBefore = plasmaVault.balanceOf(other);

        vm.prank(other);
        plasmaVault.withdraw(CRYSTALLIZER_ASSETS, other, other);

        fee.feeShares = plasmaVault.balanceOf(feeAccount) - feeSharesBefore;
        fee.feeAssets = plasmaVault.convertToAssets(fee.feeShares);
        /// @dev supply after = base (management fee already minted) + performance fee - shares the exit burned
        fee.baseSupply = plasmaVault.totalSupply() + (otherSharesBefore - plasmaVault.balanceOf(other)) - fee.feeShares;

        vm.revertToState(snapshot);
        assertGt(fee.feeShares, 0, "precondition: a performance fee is pending");
    }

    /// @dev Calls withdraw one unit above maxAssets_ and returns the limit the vault enforces in the call
    function _enforcedWithdrawLimit(address owner_, uint256 maxAssets_) internal returns (uint256 enforced) {
        uint256 snapshot = vm.snapshotState();
        vm.prank(owner_);
        (bool ok, bytes memory ret) = address(plasmaVault).call(
            abi.encodeCall(PlasmaVault.withdraw, (maxAssets_ + 1, owner_, owner_))
        );
        assertFalse(ok, "withdraw above the limit reverts");
        assertEq(bytes4(ret), EXCEEDED_MAX_WITHDRAW, "ERC4626ExceededMaxWithdraw");
        (, , enforced) = abi.decode(_slice(ret, 4), (address, uint256, uint256));
        vm.revertToState(snapshot);
    }

    // ---------------------------------------------------------------------------------------------
    // Scenarios
    // ---------------------------------------------------------------------------------------------

    /// @dev Both holders deposit, then 20 000 rewards vest linearly over 30 days in the RewardsClaimManager and 10
    ///      days pass, so the rate is above the high-water mark and the performance fee is pending
    function _setupVestingRewardsScenario() internal {
        _deposit(user, USER_DEPOSIT);
        _deposit(other, USER_DEPOSIT);

        rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(plasmaVault));
        bytes4[] memory rcmSigs = new bytes4[](2);
        rcmSigs[0] = RewardsClaimManager.setupVestingTime.selector;
        rcmSigs[1] = RewardsClaimManager.updateBalance.selector;
        accessManager.setTargetFunctionRole(address(rewardsClaimManager), rcmSigs, Roles.ATOMIST_ROLE);
        PlasmaVaultGovernance(address(plasmaVault)).setRewardsClaimManagerAddress(address(rewardsClaimManager));

        /// @dev empty manager: anchors the schedule
        rewardsClaimManager.setupVestingTime(VESTING_TIME);
        /// @dev rewards claimed and swapped into the underlying, then linear vesting starts
        asset.mint(address(rewardsClaimManager), VESTED_REWARDS);
        rewardsClaimManager.updateBalance();

        vm.warp(block.timestamp + 10 days);
    }

    /// @dev A withdraw fee is set and an unrelated holder exits: its performance fee check runs with the rate at the
    ///      high-water mark (no fee), then its withdraw fee shares are burned, which lifts the rate above it
    function _setupWithdrawFeeBurnScenario() internal {
        withdrawManager.updateWithdrawFee(WITHDRAW_FEE);

        _deposit(user, USER_DEPOSIT);
        _deposit(other, USER_DEPOSIT);
        vm.warp(block.timestamp + 1 days);

        vm.prank(other);
        plasmaVault.withdraw(USER_DEPOSIT / 2, other, other);
    }

    /// @dev Fully allocated to the market, 1% lost in the market a day before the exit, cache not refreshed
    function _setupStaleMarketScenario() internal {
        _deploy(0, true);
        _deposit(user, USER_DEPOSIT);
        _deposit(other, USER_DEPOSIT);
        /// @dev fully allocated, so every exit goes through the instant withdrawal path and refreshes the cache
        _supplyToMarket(2 * USER_DEPOSIT);
        market.slash(address(plasmaVault), MARKET_LOSS);
        vm.warp(block.timestamp + 1 days);
    }

    function _deploy(uint256 performanceFee_, bool withMarket_) internal {
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
        sources[0] = address(new FixedValuePriceFeed(1e8));
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        accessManager = _createAccessManager();
        withdrawManager = new WithdrawManager(address(accessManager));

        plasmaVault = new PlasmaVault();
        plasmaVault.proxyInitialize(
            PlasmaVaultInitData(
                "IPOR Fusion mUSDC",
                "ipfmUSDC",
                address(asset),
                address(priceOracleMiddlewareProxy),
                FeeConfig({
                    iporDaoManagementFee: MANAGEMENT_FEE,
                    iporDaoPerformanceFee: performanceFee_,
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

        address[] memory fuses;
        MarketBalanceFuseConfig[] memory balanceFuses;
        MarketSubstratesConfig[] memory marketConfigs;

        if (withMarket_) {
            market = new ResidualsMarket(address(asset));
            supplyFuse = new ResidualsSupplyFuse(MARKET_ID, address(market));
            fuses = new address[](1);
            fuses[0] = address(supplyFuse);
            balanceFuses = new MarketBalanceFuseConfig[](1);
            balanceFuses[0] = MarketBalanceFuseConfig({
                marketId: MARKET_ID,
                fuse: address(new ResidualsBalanceFuse(MARKET_ID, address(market)))
            });
            marketConfigs = new MarketSubstratesConfig[](1);
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = PlasmaVaultConfigLib.addressToBytes32(address(asset));
            marketConfigs[0] = MarketSubstratesConfig({marketId: MARKET_ID, substrates: substrates});
        } else {
            fuses = new address[](0);
            balanceFuses = new MarketBalanceFuseConfig[](0);
            marketConfigs = new MarketSubstratesConfig[](0);
        }

        PlasmaVaultConfigurator.setupPlasmaVault(vm, atomist, address(plasmaVault), fuses, balanceFuses, marketConfigs);

        bytes4[] memory vaultSigs = new bytes4[](2);
        vaultSigs[0] = PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector;
        vaultSigs[1] = PlasmaVaultGovernance.configureInstantWithdrawalFuses.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), vaultSigs, Roles.ATOMIST_ROLE);

        bytes4[] memory updateSig = new bytes4[](1);
        updateSig[0] = PlasmaVault.updateMarketsBalances.selector;
        accessManager.setTargetFunctionRole(address(plasmaVault), updateSig, Roles.UPDATE_MARKETS_BALANCES_ROLE);
        accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, alpha, 0);

        bytes4[] memory withdrawFeeSig = new bytes4[](1);
        withdrawFeeSig[0] = WithdrawManager.updateWithdrawFee.selector;
        accessManager.setTargetFunctionRole(address(withdrawManager), withdrawFeeSig, Roles.ATOMIST_ROLE);

        if (withMarket_) {
            InstantWithdrawalFusesParamsStruct[] memory instantFuses = new InstantWithdrawalFusesParamsStruct[](1);
            instantFuses[0] = InstantWithdrawalFusesParamsStruct({fuse: address(supplyFuse), params: new bytes32[](1)});
            PlasmaVaultGovernance(address(plasmaVault)).configureInstantWithdrawalFuses(instantFuses);
        }

        _fund(user, USER_DEPOSIT);
        _fund(other, USER_DEPOSIT);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _supplyToMarket(uint256 amount_) internal {
        FuseAction[] memory calls = new FuseAction[](1);
        calls[0] = FuseAction({fuse: address(supplyFuse), data: abi.encodeWithSignature("enter(uint256)", amount_)});
        vm.prank(alpha);
        plasmaVault.execute(calls);
    }

    /// @dev Supply once the pending management fee is minted, the way realization does it (Floor on the raw supply)
    function _supplyAfterManagementFee() internal view returns (uint256) {
        return plasmaVault.totalSupply() + plasmaVault.convertToShares(plasmaVault.getUnrealizedManagementFee());
    }

    function _slice(bytes memory data_, uint256 start_) private pure returns (bytes memory out) {
        out = new bytes(data_.length - start_);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data_[start_ + i];
        }
    }

    function _deposit(address user_, uint256 amount_) internal {
        vm.prank(user_);
        plasmaVault.deposit(amount_, user_);
    }

    function _fund(address user_, uint256 amount_) internal {
        asset.mint(user_, amount_);
        vm.prank(user_);
        asset.approve(address(plasmaVault), type(uint256).max);
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
