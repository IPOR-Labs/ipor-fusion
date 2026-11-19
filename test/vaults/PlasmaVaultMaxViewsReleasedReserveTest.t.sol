// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";

import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {TestAddresses} from "../test_helpers/TestAddresses.sol";

import {RequestBackingTestBase} from "./request_backing/RequestBackingTestBase.sol";

/// @notice IL-9624 follow-up: `maxWithdraw` and `maxRedeem` cap the owner's gross shares by the shares that the
///         WithdrawManager lets one exit burn next to the released requests. `withdraw` and `redeem` revert
///         `WithdrawManagerInvalidSharesToRelease` when the idle assets in shares are below the released shares R plus
///         the gross shares of the exit, and requested shares stay in the requester's balance, so before the cap the
///         views reported positions that the exit refused (ERC-4626: the max views must not be higher than what the
///         call accepts). The cap takes all gross assets as idle, so it is an upper bound; with R = 0 the views keep
///         the balance.
/// @dev Harness: a real PlasmaVault clone with a one-day redemption delay, a 1 % withdraw fee and a WithdrawManager
///      (RequestBackingTestBase); all assets stay idle, so the cap is exact here.
contract PlasmaVaultMaxViewsReleasedReserveTest is RequestBackingTestBase {
    bytes4 internal constant INVALID_SHARES_TO_RELEASE =
        bytes4(keccak256("WithdrawManagerInvalidSharesToRelease(uint256,uint256,uint256)"));

    /// @dev The requester alone: every share is released, so an instant exit can burn only the virtual offset
    function testShouldCapMaxRedeemAndMaxWithdrawByReleasedShares_whenRequesterHoldsEverything() public {
        // given
        uint256 q = _honestScenario();
        assertEq(wm.getSharesToRelease(), q, "precondition: the whole position is released");
        uint256 balance = vault.balanceOf(HONEST);
        assertEq(balance, q, "precondition: requested shares stay in the balance");

        // then
        uint256 maxShares = vault.maxRedeem(HONEST);
        assertLt(maxShares, balance / 1e6, "maxRedeem leaves the released shares to redeemFromRequest");
        uint256 maxAssets = vault.maxWithdraw(HONEST);
        assertEq(maxAssets, vault.previewRedeem(maxShares), "maxWithdraw prices the capped shares");
        assertLt(maxAssets, vault.previewRedeem(balance) / 1e6, "maxWithdraw leaves the released shares too");

        // when / then - the balance, the old maxRedeem, is refused by the exit
        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(HONEST);
        vault.redeem(balance, HONEST, HONEST);

        // and the request exit still pays the whole position
        vm.prank(HONEST);
        uint256 paid = vault.redeemFromRequest(q, HONEST, HONEST);
        assertGt(paid, 0, "request paid");
        assertEq(vault.balanceOf(HONEST), 0, "position left through the request");
    }

    /// @dev A requester next to another holder: the cap is the supply less the released shares
    function testShouldRedeemAndWithdrawExactlyTheCappedMax_whenRequesterOutweighsOtherHolders() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _release(q);
        uint256 balance = vault.balanceOf(HONEST);

        // when
        uint256 maxShares = vault.maxRedeem(HONEST);
        uint256 maxAssets = vault.maxWithdraw(HONEST);

        // then
        assertLt(maxShares, balance, "maxRedeem below the balance");
        assertApproxEqRel(maxShares, vault.balanceOf(BYSTANDER), 1e12, "cap = supply less the released shares");
        assertEq(maxAssets, vault.previewRedeem(maxShares), "maxWithdraw = previewRedeem of the capped shares");

        uint256 snapshot = vm.snapshotState();
        vm.prank(HONEST);
        vault.redeem(maxShares, HONEST, HONEST);
        assertEq(vault.balanceOf(HONEST), balance - maxShares, "redeem(maxRedeem) passes");
        vm.revertToState(snapshot);

        uint256 before = usdc.balanceOf(HONEST);
        vm.prank(HONEST);
        vault.withdraw(maxAssets, HONEST, HONEST);
        assertEq(usdc.balanceOf(HONEST) - before, maxAssets, "withdraw(maxWithdraw) pays maxWithdraw");
        vm.revertToState(snapshot);

        // the uncapped values of the build before are refused
        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(HONEST);
        vault.redeem(balance, HONEST, HONEST);
    }

    /// @dev Another holder's view is not capped while it holds less than the unreserved shares
    function testShouldKeepBalanceInMaxRedeem_whenOwnerBelowUnreservedShares() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _release(q);

        // then
        uint256 balance = vault.balanceOf(BYSTANDER);
        assertEq(vault.maxRedeem(BYSTANDER), balance, "maxRedeem is the balance");
        assertEq(vault.maxWithdraw(BYSTANDER), vault.previewRedeem(balance), "maxWithdraw prices the balance");
    }

    /// @dev Without released shares the cap does not apply
    function testShouldKeepBalanceInMaxViews_whenNothingReleased() public {
        // given
        uint256 shares = _depositAndRequest(HONEST, 100_000e6);
        assertEq(wm.getSharesToRelease(), 0, "precondition: requested, not released");

        // then
        assertEq(vault.maxRedeem(HONEST), shares, "maxRedeem is the balance");
        assertEq(vault.maxWithdraw(HONEST), vault.previewRedeem(shares), "maxWithdraw prices the balance");
    }

    /// @dev The released shares cover the whole position: both views are exactly 0 (saturation, not an underflow).
    ///      Assets leave the vault (a loss), so the whole supply is worth fewer shares than R
    function testShouldReturnZeroMaxViews_whenReservedSharesCoverAllAssets() public {
        // given
        uint256 q = _honestScenario();
        uint256 lost = usdc.balanceOf(address(vault)) / 2;
        vm.prank(address(vault));
        usdc.transfer(SINK, lost);
        assertEq(wm.getSharesToRelease(), q, "precondition: the whole supply is released");

        // then
        assertEq(vault.maxRedeem(HONEST), 0, "maxRedeem is 0");
        assertEq(vault.maxWithdraw(HONEST), 0, "maxWithdraw is 0");

        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(HONEST);
        vault.redeem(1, HONEST, HONEST);
    }

    /// @dev Control: an owner inside the redemption lock reads 0 next to R > 0, as before the cap
    function testShouldReturnZeroMaxViews_whenOwnerLockedNextToReleasedShares() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _release(q);
        _deposit(BYSTANDER, 40_000e6);
        assertGt(accessManager.getAccountLockTime(BYSTANDER), block.timestamp, "precondition: bystander is locked");
        assertGt(wm.getSharesToRelease(), 0, "precondition: shares are released");

        // then
        assertEq(vault.maxRedeem(BYSTANDER), 0, "maxRedeem is 0 in the lock");
        assertEq(vault.maxWithdraw(BYSTANDER), 0, "maxWithdraw is 0 in the lock");
    }

    /// @dev An owner exempt from the redemption delay right after a deposit reads the reserve cap, not 0
    function testShouldReturnReserveCapNotZero_whenOwnerExemptFromRedemptionDelay() public {
        // given
        _deposit(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        address[] memory accounts = new address[](1);
        accounts[0] = BYSTANDER;
        vm.prank(OWNER);
        PlasmaVaultGovernance(address(vault)).setRedemptionDelayExemption(accounts, true);
        vm.warp(block.timestamp + 1);
        _release(vault.balanceOf(HONEST) + vault.balanceOf(BYSTANDER) / 2);
        assertGt(accessManager.getAccountLockTime(BYSTANDER), block.timestamp, "precondition: lock still running");

        // when
        uint256 balance = vault.balanceOf(BYSTANDER);
        uint256 maxShares = vault.maxRedeem(BYSTANDER);
        uint256 maxAssets = vault.maxWithdraw(BYSTANDER);

        // then
        assertGt(maxShares, 0, "not zeroed by the lock");
        assertLt(maxShares, balance, "capped by the reserve");
        assertEq(maxAssets, vault.previewRedeem(maxShares), "maxWithdraw prices the capped shares");

        uint256 snapshot = vm.snapshotState();
        vm.prank(BYSTANDER);
        vault.redeem(maxShares, BYSTANDER, BYSTANDER);
        assertEq(vault.balanceOf(BYSTANDER), balance - maxShares, "redeem(maxRedeem) passes");
        vm.revertToState(snapshot);

        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(BYSTANDER);
        vault.redeem(maxShares + 1, BYSTANDER, BYSTANDER);
    }

    /// @dev The cap is an upper bound: it counts all gross assets as idle. A market value that sits in the NAV
    ///      without idle assets leaves the views positive while the exit is refused
    function testShouldKeepMaxViewsPositiveButRefuseExit_whenAssetsAreInMarketNotIdle() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 100_000e6);
        vm.warp(block.timestamp + 1 hours);
        _release(q);
        marketValue.setValue(100_000e18);
        vm.prank(ATOMIST);
        vault.updateMarketsBalances(_marketIds());
        assertEq(vault.totalAssetsInMarket(MARKET), 100_000e6, "precondition: market value counted in the NAV");
        assertEq(wm.getSharesToRelease(), q, "precondition: the request of HONEST is released");

        // when
        uint256 maxShares = vault.maxRedeem(HONEST);

        // then - the view counts the market value as available: the whole position of HONEST
        assertEq(maxShares, vault.balanceOf(HONEST), "maxRedeem is the balance");
        assertGt(vault.maxWithdraw(HONEST), 0, "maxWithdraw is positive");

        // and the exit is refused because the idle assets do not cover R plus the exit
        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(HONEST);
        vault.redeem(maxShares, HONEST, HONEST);
    }

    /// @dev Assumptions of the property: positive maxima, caller = owner after the lock, no pre-hook, all assets idle,
    ///      no valuation change between the views and the call. Holders: HONEST (requests everything) and BYSTANDER;
    ///      deposits 1 to 1 000 000 USDC; R in (0, supply]
    function testFuzzShouldRedeemMaxRedeemAndWithdrawMaxWithdraw_whenSharesReleased(
        uint256 honestAssets_,
        uint256 bystanderAssets_,
        uint256 releaseSeed_
    ) public {
        // given
        honestAssets_ = bound(honestAssets_, 1e6, 1_000_000e6);
        bystanderAssets_ = bound(bystanderAssets_, 1e6, 1_000_000e6);
        _depositAndRequest(HONEST, honestAssets_);
        _deposit(BYSTANDER, bystanderAssets_);
        vm.warp(block.timestamp + DELAY + 1);
        _release(bound(releaseSeed_, 1, vault.totalSupply()));

        address[2] memory owners = [HONEST, BYSTANDER];
        for (uint256 i; i < owners.length; ++i) {
            address owner = owners[i];
            uint256 maxShares = vault.maxRedeem(owner);
            uint256 maxAssets = vault.maxWithdraw(owner);
            if (maxShares == 0 || maxAssets == 0) {
                /// @dev Only this owner has nothing to exit (the cap leaves it 0); the other owner is still checked
                continue;
            }
            assertLe(maxShares, vault.balanceOf(owner), "maxRedeem is at most the balance");
            assertEq(maxAssets, vault.previewRedeem(maxShares), "maxWithdraw = previewRedeem(maxRedeem)");

            uint256 snapshot = vm.snapshotState();
            vm.prank(owner);
            vault.redeem(maxShares, owner, owner);
            vm.revertToState(snapshot);

            uint256 before = usdc.balanceOf(owner);
            vm.prank(owner);
            vault.withdraw(maxAssets, owner, owner);
            assertEq(usdc.balanceOf(owner) - before, maxAssets, "withdraw(maxWithdraw) pays maxWithdraw");
            vm.revertToState(snapshot);

            /// @dev One share above the cap is refused by the WithdrawManager, for an owner that the cap binds and
            ///      that has balance headroom (balance above maxRedeem)
            if (vault.balanceOf(owner) > maxShares) {
                vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
                vm.prank(owner);
                vault.redeem(maxShares + 1, owner, owner);
                vm.revertToState(snapshot);
            }
        }
    }

    /// @dev C9 order: the closed flag is read before the reserve. With R > 0 and `getSharesToRelease` reverting, a
    ///      closed vault still answers 0 on all four views; the open vault would bubble the revert
    function testShouldReturnZeroMaxViewsWithoutReadingReserve_whenVaultClosedAndReserveReadReverts() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _release(q);
        assertGt(wm.getSharesToRelease(), 0, "precondition: R > 0");
        vm.mockCallRevert(address(wm), abi.encodeWithSelector(wm.getSharesToRelease.selector), "reserve read");

        // control: the open vault reads the reserve and bubbles the revert (all four views)
        vm.expectRevert();
        vault.maxRedeem(HONEST);
        vm.expectRevert();
        vault.maxWithdraw(HONEST);

        // when
        vm.prank(TestAddresses.GUARDIAN);
        accessManager.updateTargetClosed(address(vault), true);

        // then
        assertEq(vault.maxRedeem(HONEST), 0, "maxRedeem is 0 while closed");
        assertEq(vault.maxWithdraw(HONEST), 0, "maxWithdraw is 0 while closed");
        assertEq(vault.maxDeposit(BYSTANDER), 0, "maxDeposit is 0 while closed");
        assertEq(vault.maxMint(BYSTANDER), 0, "maxMint is 0 while closed");
    }

    /// @dev Ordering consequence (operations): from the same state, request-first consumes the released request and
    ///      leaves nothing reserved; instant-first shrinks the requester's request cap by the burned shares, so after
    ///      the rest of the request is redeemed a part of R is reserved for nobody and binds the other holder
    function testShouldLeaveReserveUnclaimable_whenInstantRedeemRunsBeforeRedeemFromRequest() public {
        // given
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _release(q);
        uint256 capped = vault.maxRedeem(HONEST);
        assertGt(capped, 0, "precondition: the cap leaves an instant part");
        assertLt(capped, q, "precondition: the cap binds");
        uint256 snapshot = vm.snapshotState();

        // when - request-first, then the instant part of what is left (nothing)
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);

        // then - R is consumed, the other holder is not bound
        assertEq(wm.getSharesToRelease(), 0, "request-first: R consumed");
        assertEq(vault.maxRedeem(BYSTANDER), vault.balanceOf(BYSTANDER), "request-first: bystander unbound");
        uint256 bystanderShares = vault.balanceOf(BYSTANDER);
        vm.prank(BYSTANDER);
        vault.redeem(bystanderShares, BYSTANDER, BYSTANDER);
        vm.revertToState(snapshot);

        // when - instant-first: redeem(maxRedeem) burns `capped` shares and shrinks the request cap to the balance
        vm.prank(HONEST);
        vault.redeem(capped, HONEST, HONEST);
        assertEq(vault.getRequestCap(HONEST), q - capped, "instant-first: the request cap shrinks to the balance");

        // the full request is refused by the cap, only the remaining balance can be redeemed from the request
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawManager.WithdrawManagerRequestCapExceeded.selector, HONEST, q - capped, q)
        );
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
        vm.prank(HONEST);
        vault.redeemFromRequest(q - capped, HONEST, HONEST);

        // then - `capped` shares of the request and of R are left, with no balance behind them
        assertEq(vault.balanceOf(HONEST), 0, "instant-first: requester has no balance");
        assertEq(_requestShares(HONEST), capped, "instant-first: part of the request stays");
        uint256 stuck = wm.getSharesToRelease();
        assertEq(stuck, capped, "instant-first: part of R is reserved for nobody");
        vm.expectRevert(
            abi.encodeWithSelector(WithdrawManager.WithdrawManagerRequestCapExceeded.selector, HONEST, 0, capped)
        );
        vm.prank(HONEST);
        vault.redeemFromRequest(capped, HONEST, HONEST);

        // and it restricts the other holder: the whole balance is refused, only the cap is allowed
        uint256 bystanderBalance = vault.balanceOf(BYSTANDER);
        assertLt(vault.maxRedeem(BYSTANDER), bystanderBalance, "instant-first: bystander is bound");
        vm.expectPartialRevert(INVALID_SHARES_TO_RELEASE);
        vm.prank(BYSTANDER);
        vault.redeem(bystanderBalance, BYSTANDER, BYSTANDER);

        // until ALPHA releases again (lowers R)
        _release(0);
        assertEq(vault.maxRedeem(BYSTANDER), bystanderBalance, "new release: bystander unbound");
    }

    /// @dev The documented exit order for an owner bound by the reserve: redeemFromRequest first, then
    ///      redeem(maxRedeem) pays the rest of the position
    function testShouldExitWholePosition_whenRedeemFromRequestRunsBeforeRedeemMaxRedeem() public {
        // given - the requester releases only part of its position: the rest is bound by R
        uint256 shares = _depositAndRequest(HONEST, 100_000e6);
        _deposit(BYSTANDER, 40_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        uint256 released = shares / 2;
        _release(released);

        // when
        vm.prank(HONEST);
        vault.redeemFromRequest(released, HONEST, HONEST);

        // then
        assertEq(wm.getSharesToRelease(), 0, "R consumed by the request exit");
        uint256 rest = vault.balanceOf(HONEST);
        assertEq(rest, shares - released, "rest of the position stays");
        assertEq(vault.maxRedeem(HONEST), rest, "maxRedeem is the rest");
        vm.prank(HONEST);
        vault.redeem(rest, HONEST, HONEST);
        assertEq(vault.balanceOf(HONEST), 0, "position left");
    }

    function _marketIds() private pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = MARKET;
    }
}
