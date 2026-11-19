// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {Erc4626SupplyFuse, Erc4626SupplyFuseEnterData} from "../../../contracts/fuses/erc4626/Erc4626SupplyFuse.sol";
import {Erc4626BalanceFuse} from "../../../contracts/fuses/erc4626/Erc4626BalanceFuse.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreHookWiringLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreHookWiringLib.sol";
import {HyperCorePendingLib} from "../../../contracts/fuses/hypercore/lib/HyperCorePendingLib.sol";
import {HyperCoreCapitalFlowFullRefreshPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowFullRefreshPreHook.sol";
import {MockERC4626} from "../../test_helpers/MockErc4626.sol";

/// @notice IL-9628 (M38): `HyperCoreCapitalFlowFullRefreshPreHook` on a vault that mixes HyperCore (market 55) with two
///         ERC4626 markets. `HyperCoreCapitalFlowPreHook` (installed by the base fixture) refreshes market 55 only, so
///         the ERC4626 markets are priced from their cache on a share-priced flow; the new hook refreshes them too.
contract HyperCoreCapitalFlowFullRefreshPreHookTest is HyperCoreEffectSettlementBase {
    uint256 internal constant MARKET_VENUE = IporFusionMarkets.ERC4626_0001;
    uint256 internal constant MARKET_VENUE_EXCLUDED = IporFusionMarkets.ERC4626_0002;
    uint256 internal constant IN_VENUE = 200_000e6;
    uint256 internal constant GAIN = 50_000e6;
    uint256 internal constant DEPOSIT = 100_000e6;

    MockERC4626 internal _venue;
    MockERC4626 internal _venueExcluded;
    HyperCoreCapitalFlowFullRefreshPreHook internal _fullRefresh;

    function setUp() public override {
        super.setUp();

        _venue = new MockERC4626(_usdc, "Venue", "V");
        _venueExcluded = new MockERC4626(_usdc, "Venue excluded", "VX");
        Erc4626SupplyFuse supplyFuse = new Erc4626SupplyFuse(MARKET_VENUE);
        Erc4626SupplyFuse supplyFuseExcluded = new Erc4626SupplyFuse(MARKET_VENUE_EXCLUDED);

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuse);
        fuses[1] = address(supplyFuseExcluded);
        vm.startPrank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).addFuses(fuses);
        PlasmaVaultGovernance(address(_vault)).addBalanceFuse(
            MARKET_VENUE,
            address(new Erc4626BalanceFuse(MARKET_VENUE))
        );
        PlasmaVaultGovernance(address(_vault)).addBalanceFuse(
            MARKET_VENUE_EXCLUDED,
            address(new Erc4626BalanceFuse(MARKET_VENUE_EXCLUDED))
        );
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(MARKET_VENUE, _substrate(address(_venue)));
        PlasmaVaultGovernance(address(_vault)).grantMarketSubstrates(
            MARKET_VENUE_EXCLUDED,
            _substrate(address(_venueExcluded))
        );
        vm.stopPrank();

        FuseAction[] memory enter = new FuseAction[](2);
        enter[0] = FuseAction(
            address(supplyFuse),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(_venue), IN_VENUE, 0)))
        );
        enter[1] = FuseAction(
            address(supplyFuseExcluded),
            abi.encodeCall(Erc4626SupplyFuse.enter, (Erc4626SupplyFuseEnterData(address(_venueExcluded), IN_VENUE, 0)))
        );
        _vault.execute(enter);

        _fullRefresh = new HyperCoreCapitalFlowFullRefreshPreHook();

        _usdc.mint(_secondUser, 10 * DEPOSIT);
        vm.prank(_secondUser);
        _usdc.approve(address(_vault), type(uint256).max);
    }

    /// @dev Pins the old behaviour (control): market 55 is refreshed, the ERC4626 markets are priced from their cache,
    ///      so a depositor gets more shares than the fresh price gives. This is the M38 misbehaviour on a mixed vault.
    function testOldHookPricesMixedVaultFromStaleCache() public {
        _gainInBothVenues();
        uint256 expectedFresh = _freshPreviewDeposit(DEPOSIT);

        uint256 cachedBefore = _vault.totalAssetsInMarket(MARKET_VENUE);
        vm.prank(_secondUser);
        uint256 shares = _vault.deposit(DEPOSIT, _secondUser);

        assertEq(_vault.totalAssetsInMarket(MARKET_VENUE), cachedBefore, "old hook leaves the ERC4626 market cache");
        assertGt(shares, expectedFresh, "depositor is priced from the stale cache and over-receives shares");
    }

    /// @dev The same scenario with the new hook: shares are priced at the fresh price and both ERC4626 caches move.
    function testFullRefreshHookPricesMixedVaultAtFreshNav() public {
        _gainInBothVenues();
        uint256 expectedFresh = _freshPreviewDeposit(DEPOSIT);
        uint256 cachedBefore = _vault.totalAssetsInMarket(MARKET_VENUE);
        _wireFullRefresh(new bytes32[](0));

        vm.prank(_secondUser);
        uint256 shares = _vault.deposit(DEPOSIT, _secondUser);

        assertEq(shares, expectedFresh, "shares are priced at the fresh NAV");
        assertGt(_vault.totalAssetsInMarket(MARKET_VENUE), cachedBefore, "market refreshed");
        assertGt(
            _vault.totalAssetsInMarket(MARKET_VENUE_EXCLUDED),
            IN_VENUE,
            "second market refreshed when not excluded"
        );
    }

    /// @dev Withdraw path (share-priced too) also refreshes: the redeemer is not paid from a stale cache.
    function testFullRefreshHookRedeemUsesFreshNav() public {
        vm.prank(_secondUser);
        uint256 shares = _vault.deposit(DEPOSIT, _secondUser);
        _gainInBothVenues();
        uint256 expectedFresh = _freshPreviewRedeem(shares);
        uint256 snapshot = vm.snapshotState();
        vm.prank(_secondUser);
        uint256 assetsOld = _vault.redeem(shares, _secondUser, _secondUser);
        vm.revertToState(snapshot);

        _wireFullRefresh(new bytes32[](0));
        vm.prank(_secondUser);
        uint256 assetsNew = _vault.redeem(shares, _secondUser, _secondUser);

        assertEq(assetsNew, expectedFresh, "redeem pays the fresh NAV");
        assertGt(assetsNew, assetsOld, "the stale-cache redeem underpaid");
    }

    /// @dev A market in the exclusion list keeps its cache; the others are refreshed.
    function testExcludedMarketIsNotRefreshed() public {
        _gainInBothVenues();
        bytes32[] memory excluded = new bytes32[](1);
        excluded[0] = bytes32(MARKET_VENUE_EXCLUDED);
        _wireFullRefresh(excluded);

        uint256 cachedExcluded = _vault.totalAssetsInMarket(MARKET_VENUE_EXCLUDED);
        uint256 cachedIncluded = _vault.totalAssetsInMarket(MARKET_VENUE);
        vm.prank(_secondUser);
        assertGt(_vault.deposit(DEPOSIT, _secondUser), 0);

        assertEq(_vault.totalAssetsInMarket(MARKET_VENUE_EXCLUDED), cachedExcluded, "excluded market keeps its cache");
        assertGt(_vault.totalAssetsInMarket(MARKET_VENUE), cachedIncluded, "other market refreshed");
    }

    /// @dev HyperCore can not be excluded: the gates and the market 55 refresh run regardless.
    function testHyperCoreEntryInExclusionListIsIgnored() public {
        bytes32[] memory excluded = new bytes32[](1);
        excluded[0] = bytes32(IporFusionMarkets.HYPERCORE);
        _wireFullRefresh(excluded);
        _depositToCore(100_000e6);
        vm.expectPartialRevert(HyperCorePendingLib.HyperCoreActionPending.selector);
        vm.prank(_secondUser);
        _vault.deposit(DEPOSIT, _secondUser);
    }

    /// @dev The HyperCore action fuses accept the new hook as the capital-flow hook (marker), so exposure can be created.
    function testWiringGateAcceptsFullRefreshHook() public {
        assertEq(_fullRefresh.HYPERCORE_CAPITAL_FLOW_PRE_HOOK_ID(), HyperCoreHookWiringLib.CAPITAL_FLOW_PRE_HOOK_ID);
        _wireFullRefresh(new bytes32[](0));
        _depositToCore(100_000e6);
        assertTrue(_isPending(), "deposit to Core went through the wiring gate");
    }

    /// @dev HyperCore gates still revert: pending transfer blocks share-priced flows.
    function testPendingTransferStillBlocksUserFlows() public {
        _wireFullRefresh(new bytes32[](0));
        _depositToCore(100_000e6);
        assertTrue(_isPending());

        vm.expectPartialRevert(HyperCorePendingLib.HyperCoreActionPending.selector);
        vm.prank(_secondUser);
        _vault.deposit(DEPOSIT, _secondUser);

        vm.expectPartialRevert(HyperCorePendingLib.HyperCoreActionPending.selector);
        vm.prank(_user);
        _vault.redeem(1e6, _user, _user);
    }

    function testRunRevertsUnderExecuteAndUpdateMarketsBalances() public {
        bytes memory err = abi.encodeWithSelector(
            HyperCoreCapitalFlowFullRefreshPreHook.HyperCorePreHookWrongSelector.selector,
            PlasmaVault.execute.selector
        );
        vm.expectRevert(err);
        _fullRefresh.run(PlasmaVault.execute.selector);

        err = abi.encodeWithSelector(
            HyperCoreCapitalFlowFullRefreshPreHook.HyperCorePreHookWrongSelector.selector,
            PlasmaVault.updateMarketsBalances.selector
        );
        vm.expectRevert(err);
        _fullRefresh.run(PlasmaVault.updateMarketsBalances.selector);
    }

    // ---------------------------------------------------------------------------------------------------------------

    function _gainInBothVenues() private {
        _usdc.mint(address(_venue), GAIN);
        _usdc.mint(address(_venueExcluded), GAIN);
    }

    /// @dev previewDeposit on the fresh NAV; the refresh is rolled back.
    function _freshPreviewDeposit(uint256 assets_) private returns (uint256 shares) {
        uint256 snapshot = vm.snapshotState();
        _refreshAll();
        shares = _vault.previewDeposit(assets_);
        vm.revertToState(snapshot);
    }

    function _freshPreviewRedeem(uint256 shares_) private returns (uint256 assets) {
        uint256 snapshot = vm.snapshotState();
        _refreshAll();
        assets = _vault.previewRedeem(shares_);
        vm.revertToState(snapshot);
    }

    function _refreshAll() private {
        uint256[] memory markets = new uint256[](3);
        markets[0] = MARKET_ID;
        markets[1] = MARKET_VENUE;
        markets[2] = MARKET_VENUE_EXCLUDED;
        vm.prank(_atomist);
        _vault.updateMarketsBalances(markets);
    }

    function _wireFullRefresh(bytes32[] memory excluded_) private {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.depositWithPermit.selector;
        selectors[2] = PlasmaVault.mint.selector;
        selectors[3] = PlasmaVault.withdraw.selector;
        selectors[4] = PlasmaVault.redeem.selector;
        selectors[5] = PlasmaVault.redeemFromRequest.selector;
        address[] memory implementations = new address[](6);
        bytes32[][] memory substrates = new bytes32[][](6);
        for (uint256 i; i < 6; ++i) {
            implementations[i] = address(_fullRefresh);
            substrates[i] = excluded_;
        }
        vm.prank(_atomist);
        PlasmaVaultGovernance(address(_vault)).setPreHookImplementations(selectors, implementations, substrates);
    }

    function _depositToCore(uint256 amount_) private {
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

    function _substrate(address venue_) private pure returns (bytes32[] memory substrates) {
        substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(venue_);
    }
}
