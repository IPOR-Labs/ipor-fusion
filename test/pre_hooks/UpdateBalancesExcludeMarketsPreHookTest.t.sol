// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {UpdateBalancesPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesPreHook.sol";
import {UpdateBalancesExcludeMarketsPreHook} from "../../contracts/handlers/pre_hooks/pre_hooks/UpdateBalancesExcludeMarketsPreHook.sol";
import {PlasmaVaultMockMarketsTestBase} from "../vaults/PlasmaVaultMockMarketsTestBase.sol";

/// @title UpdateBalancesExcludeMarketsPreHookTest
/// @notice IL-9609 (M19): a vault with a live EulerSwap pool must not let a user operation refresh market 11 (IL-9331),
///         and with UpdateBalancesPreHook it could not refresh any other market on user selectors either.
///         UpdateBalancesExcludeMarketsPreHook refreshes every active market except the configured ones.
/// @dev The pool market (EULER_V2, 11 in production) is stood in by market A of the shared fixture: its value is moved
///      by `_accrue` / `_loss` like a trader moves a pool with a swap, without a booked refresh. The scenario tests
///      keep the UpdateBalancesPreHook run as a control: the new contract does not exist on the base commit, so the
///      base behaviour (the user operation books the moved pool value into the share price) is pinned with the old hook.
contract UpdateBalancesExcludeMarketsPreHookTest is PlasmaVaultMockMarketsTestBase {
    uint256 public constant AMOUNT = 1_000_000e6;
    /// @dev Absolute dust allowed on a fair price (virtual offset and rounding of the vault), 0.01 asset unit
    uint256 public constant DUST = 1e4;

    function _performanceFee() internal pure override returns (uint256) {
        return 0;
    }

    function setUp() public override {
        super.setUp();
        _deposit(user, AMOUNT);
        _allocate(address(marketA), AMOUNT / 2);
        _allocate(address(marketB), AMOUNT / 2);
    }

    // ------------------------------------------------------------------ unit behaviour

    function testShouldNotRefreshExcludedMarketAndRefreshOthersOnDeposit() public {
        _wireExclude(PlasmaVault.deposit.selector, _one(MARKET_A));
        uint256 cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 cachedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        _accrue(address(marketA), 1000);
        _accrue(address(marketB), 1000);

        _deposit(other, 1_000e6);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), cachedA, "excluded market keeps its cached balance");
        assertGt(plasmaVault.totalAssetsInMarket(MARKET_B), cachedB, "market that is not excluded is refreshed");
    }

    function testShouldRefreshAllMarketsWhenExclusionListIsEmptyLikeUpdateBalancesPreHook() public {
        _wireExclude(PlasmaVault.deposit.selector, new bytes32[](0));
        uint256 cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 cachedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        _accrue(address(marketA), 1000);
        _accrue(address(marketB), 1000);

        _deposit(other, 1_000e6);

        uint256 refreshedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 refreshedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        assertGt(refreshedA, cachedA, "market A refreshed");
        assertGt(refreshedB, cachedB, "market B refreshed");

        /// @dev Same state through the old hook on an identical vault state gives the same cached values
        _wireOld(PlasmaVault.deposit.selector);
        uint256 snapshot = vm.snapshotState();
        _deposit(other, 1_000e6);
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), refreshedA, "A: same as UpdateBalancesPreHook");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), refreshedB, "B: same as UpdateBalancesPreHook");
        assertTrue(vm.revertToState(snapshot));
    }

    function testShouldNotRevertAndRefreshNothingWhenEveryActiveMarketIsExcluded() public {
        bytes32[] memory all = new bytes32[](2);
        all[0] = bytes32(MARKET_A);
        all[1] = bytes32(MARKET_B);
        _wireExclude(PlasmaVault.deposit.selector, all);
        uint256 cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 cachedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        _accrue(address(marketA), 1000);
        _accrue(address(marketB), 1000);

        _deposit(other, 1_000e6);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), cachedA);
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), cachedB);
    }

    function testShouldIgnoreListedMarketThatIsNotActiveAndDuplicates() public {
        bytes32[] memory list = new bytes32[](3);
        list[0] = bytes32(uint256(11));
        list[1] = bytes32(MARKET_A);
        list[2] = bytes32(MARKET_A);
        _wireExclude(PlasmaVault.deposit.selector, list);
        uint256 cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 cachedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        _accrue(address(marketA), 1000);
        _accrue(address(marketB), 1000);

        _deposit(other, 1_000e6);

        assertEq(plasmaVault.totalAssetsInMarket(MARKET_A), cachedA, "A stays excluded");
        assertGt(plasmaVault.totalAssetsInMarket(MARKET_B), cachedB, "B refreshed");
    }

    function testShouldRevertWhenExcludedMarketIdIsZero() public {
        _wireExclude(PlasmaVault.deposit.selector, _one(0));

        vm.expectRevert(UpdateBalancesExcludeMarketsPreHook.InvalidExcludedMarketId.selector);
        vm.prank(other);
        plasmaVault.deposit(1_000e6, other);
    }

    function testShouldUseExclusionListOfTheSelectorItRunsOn() public {
        _wireExclude(PlasmaVault.deposit.selector, _one(MARKET_A));
        _wireExclude(PlasmaVault.redeem.selector, _one(MARKET_B));
        _deposit(other, AMOUNT);
        uint256 cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        uint256 cachedB = plasmaVault.totalAssetsInMarket(MARKET_B);
        _accrue(address(marketA), 1000);
        _accrue(address(marketB), 1000);

        uint256 shares = plasmaVault.balanceOf(other) / 10;
        vm.prank(other);
        plasmaVault.redeem(shares, other, other);

        assertGt(plasmaVault.totalAssetsInMarket(MARKET_A), cachedA, "redeem refreshes A");
        assertEq(plasmaVault.totalAssetsInMarket(MARKET_B), cachedB, "redeem leaves its excluded market B");
    }

    // ------------------------------------------------------------------ IL-9609 scenario: swap, user operation, swap back

    /// @dev Control, base behaviour: with UpdateBalancesPreHook the redeem books the pool value that the trader's swap
    ///      moved up, so the redeemer is paid above the pre-swap price, and after the swap back the cache stays inflated
    function testShouldBookSwapMovedPoolValueIntoRedeemPriceWithUpdateBalancesPreHook() public {
        (uint256 paid, uint256 fair, uint256 cachedA, uint256 realA) = _swapRedeemSwapBack(false);

        assertGt(paid, fair + DUST, "premise: the swap moved the price the redeemer was paid at");
        assertGt(cachedA, realA, "the inflated pool value stays in the share price after the swap back");
    }

    /// @dev With the exclusion hook the redeem is paid at the price before the swap and the cache is not moved
    function testShouldPayRedeemAtPreSwapPriceAndKeepCacheWhenPoolMarketIsExcluded() public {
        (uint256 paid, uint256 fair, uint256 cachedA, uint256 realA) = _swapRedeemSwapBack(true);

        assertApproxEqAbs(paid, fair, DUST, "redeem is priced on the cache from before the swap");
        assertApproxEqAbs(
            cachedA,
            realA,
            DUST,
            "no inflated value is recorded: cache equals the real value after swap back"
        );
    }

    /// @dev Same on deposit: the swap-then-deposit path cannot choose the pool state that prices the entry
    function testShouldPriceDepositAtPreSwapRateWhenPoolMarketIsExcluded() public {
        _wireExclude(PlasmaVault.deposit.selector, _one(MARKET_A));
        uint256 rateBefore = _rate();
        _accrue(address(marketA), 2000);

        _deposit(other, AMOUNT);

        uint256 value = plasmaVault.convertToAssets(plasmaVault.balanceOf(other));
        assertApproxEqAbs(value, AMOUNT, DUST * 10, "entered at the pre-swap rate, nothing is shifted");
        assertApproxEqAbs(_rate(), rateBefore, 1e3, "share rate unchanged by the user operation");
    }

    function testShouldBookSwapMovedPoolValueIntoDepositPriceWithUpdateBalancesPreHook() public {
        _wireOld(PlasmaVault.deposit.selector);
        uint256 rateBefore = _rate();
        _accrue(address(marketA), 2000);

        _deposit(other, AMOUNT);

        assertGt(_rate(), rateBefore + 1e3, "control: the deposit booked the moved pool value into the share rate");
    }

    // ------------------------------------------------------------------ helpers

    /// @return paid assets paid for the redeem, fair assets at the rate before the swap, cachedA cached balance of the
    ///         pool market after the swap back, realA its real balance after the swap back
    function _swapRedeemSwapBack(
        bool excludePool_
    ) internal returns (uint256 paid, uint256 fair, uint256 cachedA, uint256 realA) {
        /// @dev The second deposit stays idle and covers the redeem, so no market is touched by the withdrawal itself
        _deposit(other, AMOUNT);
        if (excludePool_) {
            _wireExclude(PlasmaVault.redeem.selector, _one(MARKET_A));
        } else {
            _wireOld(PlasmaVault.redeem.selector);
        }
        uint256 shares = plasmaVault.balanceOf(other) / 2;
        fair = plasmaVault.convertToAssets(shares);
        uint256 poolBefore = asset.balanceOf(address(marketA));

        /// @dev Swap: the trader moves the pool value up (no refresh of the vault)
        _accrue(address(marketA), 2000);

        vm.prank(other);
        paid = plasmaVault.redeem(shares, other, other);

        /// @dev Swap back: the pool returns to its pre-swap value
        uint256 swapBack = asset.balanceOf(address(marketA)) - poolBefore;
        vm.prank(address(marketA));
        asset.transfer(address(0xdead), swapBack);

        cachedA = plasmaVault.totalAssetsInMarket(MARKET_A);
        realA = marketA.convertToAssets(marketA.balanceOf(address(plasmaVault)));
    }

    function _wireExclude(bytes4 selector_, bytes32[] memory excluded_) internal {
        _wire(selector_, address(new UpdateBalancesExcludeMarketsPreHook()), excluded_);
    }

    function _wireOld(bytes4 selector_) internal {
        _wire(selector_, address(new UpdateBalancesPreHook()), new bytes32[](0));
    }

    function _wire(bytes4 selector_, address hook_, bytes32[] memory substrates_) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory hooks = new address[](1);
        hooks[0] = hook_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = substrates_;
        PlasmaVaultGovernance(address(plasmaVault)).setPreHookImplementations(selectors, hooks, substrates);
    }

    function _one(uint256 marketId_) private pure returns (bytes32[] memory list) {
        list = new bytes32[](1);
        list[0] = bytes32(marketId_);
    }
}
