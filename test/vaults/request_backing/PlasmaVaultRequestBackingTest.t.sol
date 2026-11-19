// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";

import {RequestBackingTestBase, RequestBackingActor} from "./RequestBackingTestBase.sol";

/// @notice IL-9531: a WithdrawManager request is backed. requestShares needs the shares; the vault keeps a request cap
///         that a debit lowers to the balance left and no credit raises; redeemFromRequest redeems at most the cap;
///         a request filed during the owner's redemption lock starts when that lock ends. Later deposits to the owner
///         hold nothing, so the request path stays the exit that a third party cannot relock.
contract PlasmaVaultRequestBackingTest is RequestBackingTestBase {
    bytes4 internal constant NOT_BACKED = bytes4(keccak256("WithdrawManagerRequestNotBacked(address,uint256,uint256)"));
    bytes4 internal constant CAP_EXCEEDED =
        bytes4(keccak256("WithdrawManagerRequestCapExceeded(address,uint256,uint256)"));
    bytes4 internal constant NOT_ELIGIBLE = bytes4(keccak256("WithdrawManagerInvalidSharesToRelease(uint256)"));

    // ------------------------------------------------------------------ requestShares

    function testRequestWithoutSharesReverts() public {
        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, address(actor), 0, 1e8));
        actor.request(wm, 1e8);
    }

    function testRequestAboveBalanceReverts() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.prank(HONEST);
        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, HONEST, q, q + 1));
        wm.requestShares(q + 1);
    }

    function testRequestSetsCapToRequestedShares() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.prank(HONEST);
        wm.requestShares(q / 2);
        assertEq(_requestShares(HONEST), q / 2, "request");
        assertEq(vault.getRequestCap(HONEST), q / 2, "cap = request");
    }

    /// The balance check counts the fee (gross shares); the cap is the recorded request (net shares).
    function testRequestFeeChecksGrossSharesAndCapsNetShares() public {
        vm.prank(ATOMIST);
        wm.updateRequestFee(1e15);
        uint256 q = _deposit(HONEST, 100_000e6);

        vm.prank(HONEST);
        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, HONEST, q, q + 1));
        wm.requestShares(q + 1);

        vm.prank(HONEST);
        wm.requestShares(q);
        uint256 net = q - q / 1000;
        assertEq(_requestShares(HONEST), net, "request = shares - fee");
        assertEq(vault.getRequestCap(HONEST), net, "cap = request");
        assertEq(vault.balanceOf(HONEST), net, "fee moved out of the balance");

        vm.warp(block.timestamp + DELAY + 2);
        _release(net);
        vm.prank(HONEST);
        vault.redeemFromRequest(net, HONEST, HONEST);
    }

    /// A WithdrawManager that is not wired to its vault cannot check the balance, so it refuses every request.
    function testRequestOnUnwiredWithdrawManagerReverts() public {
        WithdrawManager unwired = new WithdrawManager(address(accessManager));
        vm.expectRevert(WithdrawManager.WithdrawManagerPlasmaVaultNotSet.selector);
        unwired.requestShares(1);
    }

    function testSetRequestCapOnlyWithdrawManager() public {
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(this)));
        vault.setRequestCap(address(this), 1);
        vm.prank(ATOMIST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, ATOMIST));
        vault.setRequestCap(ATOMIST, 1);
    }

    // ------------------------------------------------------------------ the cap follows the balance down

    function testCapFollowsBalanceDownAndNeverUp() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vault.transfer(BYSTANDER, q / 4);
        assertEq(vault.getRequestCap(HONEST), q - q / 4, "transfer out lowers the cap");
        vm.prank(BYSTANDER);
        vault.transfer(HONEST, q / 4);
        assertEq(vault.getRequestCap(HONEST), q - q / 4, "transfer in does not raise it");
        _deposit(HONEST, 10_000e6);
        assertEq(vault.getRequestCap(HONEST), q - q / 4, "deposit does not raise it");
        assertEq(vault.getRequestCap(BYSTANDER), 0, "a receiver gets no cap");
    }

    function testCapLoweredByInstantRedeem() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vault.redeem(q / 2, HONEST, HONEST);
        assertEq(vault.getRequestCap(HONEST), q - q / 2);
    }

    function testCapLoweredByWithdrawAndItsFeeBurn() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vault.withdraw(10_000e6, HONEST, HONEST);
        assertLt(vault.getRequestCap(HONEST), q, "lowered");
        assertEq(vault.getRequestCap(HONEST), vault.balanceOf(HONEST), "to the balance left after the fee burn");
    }

    function testCapLoweredWhenSpenderMovesShares() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vault.approve(BYSTANDER, q);
        vm.prank(BYSTANDER);
        vault.transferFrom(HONEST, BYSTANDER, q / 2);
        assertEq(vault.getRequestCap(HONEST), q - q / 2);
    }

    function testSelfTransferAndZeroTransferKeepCap() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.startPrank(HONEST);
        vault.transfer(HONEST, q);
        vault.transfer(BYSTANDER, 0);
        vm.stopPrank();
        assertEq(vault.getRequestCap(HONEST), q);
    }

    function testNewRequestReplacesCap() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vault.transfer(BYSTANDER, q / 2);
        vm.prank(BYSTANDER);
        vault.transfer(HONEST, q / 2);
        assertEq(vault.getRequestCap(HONEST), q - q / 2, "shrunk");
        vm.prank(HONEST);
        wm.requestShares(q);
        assertEq(vault.getRequestCap(HONEST), q, "a new request is backed by the balance again");
    }

    /// The cap is the lowest balance since the request (never above the request), for any sequence of moves.
    function testFuzzCapIsLowestBalanceSinceRequest(uint256[6] memory moves_, bool[6] memory out_) public {
        uint256 q = _deposit(HONEST, 100_000e6);
        _deposit(BYSTANDER, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(HONEST);
        wm.requestShares(q / 2);

        uint256 lowest = q / 2;
        for (uint256 i; i < 6; ++i) {
            address from = out_[i] ? HONEST : BYSTANDER;
            address to = out_[i] ? BYSTANDER : HONEST;
            uint256 amount = bound(moves_[i], 0, vault.balanceOf(from));
            vm.prank(from);
            vault.transfer(to, amount);
            uint256 balance = vault.balanceOf(HONEST);
            if (balance < lowest) {
                lowest = balance;
            }
            assertEq(vault.getRequestCap(HONEST), lowest, "cap = lowest balance since the request");
        }
    }

    // ------------------------------------------------------------------ redeemFromRequest

    function testHonestRequestRedeemsInFull() public {
        uint256 q = _honestScenario();
        vm.prank(HONEST);
        uint256 assets = vault.redeemFromRequest(q, HONEST, HONEST);
        assertApproxEqAbs(assets, 100_000e6, 1, "no withdraw fee on the request path");
        assertEq(vault.getRequestCap(HONEST), 0, "cap followed the balance to 0");
        assertEq(wm.getSharesToRelease(), 0);
    }

    function testPartialRedeemsFromOneRequest() public {
        uint256 q = _honestScenario();
        vm.startPrank(HONEST);
        vault.redeemFromRequest(q / 2, HONEST, HONEST);
        vault.redeemFromRequest(q - q / 2, HONEST, HONEST);
        vm.stopPrank();
        assertEq(vault.balanceOf(HONEST), 0);
    }

    function testSpenderRedeemsOwnersRequest() public {
        uint256 q = _honestScenario();
        vm.prank(HONEST);
        vault.approve(BYSTANDER, q);
        vm.prank(BYSTANDER);
        vault.redeemFromRequest(q, BYSTANDER, HONEST);
        assertApproxEqAbs(usdc.balanceOf(BYSTANDER), 100_000e6, 1);
    }

    /// Unchanged: a request that the release does not cover still fails in the vault with the old error.
    function testRequestNotReleasedFailsAsBefore() public {
        uint256 q = _depositAndRequest(HONEST, 100_000e6);
        vm.prank(HONEST);
        vm.expectRevert(abi.encodeWithSelector(PlasmaVault.WithdrawManagerInvalidSharesToRelease.selector, q));
        vault.redeemFromRequest(q, HONEST, HONEST);
    }

    /// Shares that leave and come back stop backing the request: it redeems the lowest balance, or file a new one.
    function testSharesMovedAwayAndBackStopBackingTheRequest() public {
        uint256 q = _honestScenario();
        vm.prank(HONEST);
        vault.transfer(BYSTANDER, q / 4);
        vm.prank(BYSTANDER);
        vault.transfer(HONEST, q / 4);
        vm.prank(HONEST);
        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, HONEST, q - q / 4, q));
        vault.redeemFromRequest(q, HONEST, HONEST);
        vm.prank(HONEST);
        vault.redeemFromRequest(q - q / 4, HONEST, HONEST);
    }

    // ------------------------------------------------------------------ the IL-9531 attacks

    /// An account without shares can no longer file the request that took the release.
    function testUnbackedRequestCannotBeFiled() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, address(actor), 0, 10 * q));
        actor.request(wm, 10 * q);
    }

    /// 3sigma's scenario with capital: backed once, shares moved on, own fresh capital a second before the redeem.
    function testBackedThenMovedRequestCannotTakeRelease() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 1_000_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, x);
        actor.transfer(vault, BYSTANDER, x);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(HONEST);
        wm.requestShares(q);
        vm.warp(block.timestamp + 1 hours);
        _release(q);

        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), vault.previewMint(q)));
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, address(actor), 0, s));
        actor.redeemFromRequest(vault, s);

        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
        assertEq(wm.getSharesToRelease(), 0, "the honest holder got the release");
    }

    /// One backed position cannot back requests on several accounts: the cap leaves with the shares.
    function testSameCapitalCannotBackTwoRequests() public {
        RequestBackingActor second = new RequestBackingActor();
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 100_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, x);
        actor.transfer(vault, address(second), x);
        second.request(wm, x);
        assertEq(vault.getRequestCap(address(actor)), 0, "first request lost its backing");
        assertEq(vault.getRequestCap(address(second)), x, "second request backed");
    }

    /// Shares minted in the same transaction (a flash loan) do not refill a request whose backing has left.
    function testFlashLoanCannotRefillAMovedRequest() public {
        uint256 x = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 200_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, x);
        actor.transfer(vault, BYSTANDER, x);
        vm.warp(block.timestamp + 1 hours);
        _release(x);
        usdc.mint(address(actor), vault.previewMint(x));
        vm.expectRevert(abi.encodeWithSelector(CAP_EXCEEDED, address(actor), 0, x));
        actor.strike(vault, IERC20(address(usdc)), x);
    }

    /// Review finding F1: a fresh deposit backs its own request at once, but cannot leave through it before its lock
    /// ends, so it cannot take a release sized for an older request either.
    function testFreshDepositCannotLeaveThroughOwnRequestBeforeLockEnds() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        vm.prank(HONEST);
        wm.requestShares(q);
        vm.warp(block.timestamp + 1 hours);

        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 100_000e6));
        actor.request(wm, s);
        uint256 lockEnd = block.timestamp + DELAY;
        assertEq(wm.requestInfo(address(actor)).endWithdrawWindowTimestamp, lockEnd + WINDOW, "starts at the lock end");
        vm.warp(block.timestamp + 2);
        _release(q);
        assertFalse(wm.requestInfo(address(actor)).canWithdraw, "not in a release before the lock end");

        vm.expectRevert(abi.encodeWithSelector(NOT_ELIGIBLE, s));
        actor.redeemFromRequest(vault, s);
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
        assertEq(wm.getSharesToRelease(), 0, "the honest holder got the release");
    }

    // ------------------------------------------------------------------ the escape hatch stays open

    /// A third party's dust deposit after the request (IL-8736 relock) does not hold the request exit at all.
    function testDustDepositAfterRequestDoesNotHoldTheExit() public {
        uint256 q = _honestScenario();
        _dustDeposit(HONEST);
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
    }

    /// Relocked before the request: the request starts at that one lock end, later dust does not move it.
    function testDustBeforeRequestStartsTheRequestAtThatLockEndOnly() public {
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _dustDeposit(HONEST);
        uint256 lockEnd = block.timestamp + DELAY;
        vm.prank(HONEST);
        wm.requestShares(q);
        vm.warp(block.timestamp + 1 hours);
        _release(q);

        vm.prank(HONEST);
        vm.expectRevert(abi.encodeWithSelector(NOT_ELIGIBLE, q));
        vault.redeemFromRequest(q, HONEST, HONEST);

        vm.warp(lockEnd - 10);
        _dustDeposit(HONEST);
        vm.warp(lockEnd + 2);
        _dustDeposit(HONEST);
        _release(q);
        assertTrue(wm.requestInfo(HONEST).canWithdraw, "eligible for a release after the lock end of the filing time");
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
    }

    /// Review finding N1: with a window shorter than the delay, a griefer who keeps the holder locked still cannot
    /// make its request expire before it can be used, because the window starts at the lock end.
    function testWindowShorterThanDelayGrieferCannotLockOutTheRequest() public {
        vm.prank(ATOMIST);
        wm.updateWithdrawWindow(12 hours);
        uint256 q = _deposit(HONEST, 100_000e6);
        vm.warp(block.timestamp + DELAY + 1);
        _dustDeposit(HONEST);
        uint256 lockEnd = block.timestamp + DELAY;
        vm.prank(HONEST);
        wm.requestShares(q);
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 6 hours);
            _dustDeposit(HONEST);
        }
        vm.warp(lockEnd + 2);
        _dustDeposit(HONEST);
        _release(q);
        vm.prank(HONEST);
        vault.redeemFromRequest(q, HONEST, HONEST);
        assertEq(wm.getSharesToRelease(), 0, "the held holder got out through its request");
    }

    /// Dispatcher / parent-vault shaped holder (owner = address(this)): a top-up after the request does not hold it.
    function testHolderTopUpAfterRequestDoesNotHoldTheExit() public {
        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 50_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, s);
        vm.warp(block.timestamp + 1 hours);
        _release(s);
        actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 10_000e6));
        actor.redeemFromRequest(vault, s);
    }

    /// Accounts exempt from the redemption delay are not held by their lock on the request path either.
    function testExemptAccountRequestIsNotHeldByItsLock() public {
        address[] memory accounts = new address[](1);
        accounts[0] = address(actor);
        vm.prank(OWNER);
        PlasmaVaultGovernance(address(vault)).setRedemptionDelayExemption(accounts, true);
        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 50_000e6));
        actor.request(wm, s);
        vm.warp(block.timestamp + 1 hours);
        _release(s);
        actor.redeemFromRequest(vault, s);
    }
}
