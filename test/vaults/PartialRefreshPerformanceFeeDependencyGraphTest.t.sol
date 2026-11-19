// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultMockMarketsTestBase} from "./PlasmaVaultMockMarketsTestBase.sol";

/// @title PartialRefreshPerformanceFeeDependencyGraphTest
/// @notice IL-9600 (M10): `updateMarketsBalances` refreshes only the listed markets (plus their dependency graph) and then
///         crystallizes the performance fee on the share price built from the cached balances of all the others. Two
///         markets whose values offset each other (a gain on A, an equal unbooked loss on B) therefore produce a
///         phantom performance fee and a raised HWM when only A is refreshed. The remedy is configuration: an edge
///         A <-> B in the dependency graph makes every refresh of one of them refresh both.
/// @dev Pinning test of documented behaviour (contracts/vaults/README.md, "Performance fee and partially refreshed NAV"):
///      it passes on the base commit, nothing in the contracts changes. The gain and the loss are equal, so after both
///      markets are booked the share price equals the HWM and no fee is owed.
contract PartialRefreshPerformanceFeeDependencyGraphTest is PlasmaVaultMockMarketsTestBase {
    uint256 public constant DEPOSIT = 1_000_000e6;
    uint256 public constant HALF = 500_000e6;
    /// @dev Unbooked move of 10% of each market balance: +50,000e6 on A, -50,000e6 on B
    uint256 public constant MOVE_BPS = 1000;

    function setUp() public override {
        super.setUp();
        _deposit(user, DEPOSIT);
        _allocate(address(marketA), HALF);
        _allocate(address(marketB), HALF);
        assertGt(_hwm(), 0, "setup: HWM initialized by the first execute");
        assertEq(asset.balanceOf(address(plasmaVault)), 0, "setup: nothing idle");
    }

    function testShouldMintPhantomPerformanceFeeWhenOnlyOneOfTwoOffsettingMarketsIsRefreshed() public {
        uint256 hwmBefore = _hwm();
        uint256 supplyBefore = plasmaVault.totalSupply();
        uint256 assetsBefore = plasmaVault.totalAssets();
        _accrue(address(marketA), MOVE_BPS);
        _loss(address(marketB), MOVE_BPS);
        uint256 gain = HALF / 10;

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids(MARKET_A));

        uint256 minted = plasmaVault.balanceOf(_feeAccount());
        assertGt(minted, 0, "the partial refresh minted a performance fee on a gain that B offsets");
        assertGt(_hwm(), hwmBefore, "the HWM was raised on the phantom gain");
        assertApproxEqAbs(
            plasmaVault.totalAssets(),
            assetsBefore + gain,
            2,
            "only A was booked, B is still at its stale value"
        );

        /// @dev Documented bound (IL-8870 formula): the fee shares are worth performanceFee x the holders' share of the
        ///      phantom delta after their own mint, i.e. supply x x / (1 - x) with
        ///      x = performanceFee x gain / (10000 x (assets + gain))
        uint256 feeValue = _performanceFee() * gain;
        uint256 upperBound = Math.mulDiv(supplyBefore, feeValue, 10_000 * (assetsBefore + gain) - feeValue);
        assertLe(minted, upperBound + 1, "fee is bounded by rate x phantom delta");

        /// @dev Once B is booked the loss shows, the rate drops below the raised HWM: the fee already minted stays
        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids(MARKET_B));
        assertLt(_rate(), _hwm(), "after B is booked the rate is below the HWM that the phantom gain set");
        assertEq(plasmaVault.balanceOf(_feeAccount()), minted, "the minted fee is not refunded");
    }

    function testShouldNotMintFeeWhenDependencyGraphLinksOffsettingMarketsBothWays() public {
        _linkMarketsBothWays();
        uint256 hwmBefore = _hwm();
        uint256 assetsBefore = plasmaVault.totalAssets();
        _accrue(address(marketA), MOVE_BPS);
        _loss(address(marketB), MOVE_BPS);

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids(MARKET_A));

        assertEq(plasmaVault.balanceOf(_feeAccount()), 0, "no fee: the refresh of A also refreshed B");
        assertEq(_hwm(), hwmBefore, "the HWM did not move");
        assertApproxEqAbs(plasmaVault.totalAssets(), assetsBefore, 2, "both markets booked, the offsets cancel");
    }

    function testShouldNotMintFeeWhenRefreshStartsFromTheOtherMarketOfTheLink() public {
        _linkMarketsBothWays();
        uint256 hwmBefore = _hwm();
        _accrue(address(marketA), MOVE_BPS);
        _loss(address(marketB), MOVE_BPS);

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids(MARKET_B));

        assertEq(plasmaVault.balanceOf(_feeAccount()), 0, "no fee: the link works from both ends");
        assertEq(_hwm(), hwmBefore, "the HWM did not move");
    }

    function testShouldStillMintPhantomFeeWhenGraphEdgeRunsOnlyOneWay() public {
        /// @dev Edge B -> A only: refreshing A does not pull in B, so the rule needs the edge in both directions
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = MARKET_B;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = _ids(MARKET_A);
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencies);
        _accrue(address(marketA), MOVE_BPS);
        _loss(address(marketB), MOVE_BPS);

        vm.prank(updater);
        plasmaVault.updateMarketsBalances(_ids(MARKET_A));

        assertGt(plasmaVault.balanceOf(_feeAccount()), 0, "a one-way edge leaves the refresh of A partial");
    }

    // ------------------------------------------------------------------ helpers

    function _linkMarketsBothWays() internal {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = MARKET_A;
        marketIds[1] = MARKET_B;
        uint256[][] memory dependencies = new uint256[][](2);
        dependencies[0] = _ids(MARKET_B);
        dependencies[1] = _ids(MARKET_A);
        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependencies);
    }

    function _ids(uint256 marketId_) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = marketId_;
    }
}
