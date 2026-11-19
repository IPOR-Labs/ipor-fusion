// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";

import {RequestBackingTestBase} from "./request_backing/RequestBackingTestBase.sol";

/// @notice IL-9679 (Olympix 2026-11-06 L48): `maxWithdraw` and `maxRedeem` return 0 while the owner's redemption lock
///         is active, because `withdraw` and `redeem` revert then (ERC-4626: the max views must return 0 when the
///         exit is disabled for the owner). The views read the lock like `RedemptionDelayLib.lockChecks`: the
///         unlock time from the access manager, compared with `>` (an exit at the unlock second goes through), and an
///         owner exempt from the redemption delay (IL-7935, IL-9634) is never zeroed. `redeemFromRequest` is
///         lock-free by design (IL-8736, IL-9531) and keeps its own cap from the owner's balance, so a holder whom a
///         third party relocks still leaves through its request while the views read 0. Outside the lock the views
///         keep the IL-9624 pricing (`maxWithdraw` equals `previewRedeem(balanceOf)`).
/// @dev Harness: a real PlasmaVault clone with a one-day redemption delay, a 1 % withdraw fee and a WithdrawManager
///      (RequestBackingTestBase); the one-second case uses the delay most live vaults run with.
contract PlasmaVaultMaxViewsRedemptionLockTest is RequestBackingTestBase {
    bytes4 internal constant ACCOUNT_IS_LOCKED = bytes4(keccak256("AccountIsLocked(uint256)"));

    uint256 internal constant DEPOSIT = 100_000e6;

    // ------------------------------------------------------------------ lock window

    function testShouldReturnZeroMaxViewsDuringLockAndFullPositionFromUnlockTime() public {
        // given
        _deposit(HONEST, DEPOSIT);
        uint256 unlockTime = block.timestamp + DELAY;
        assertEq(accessManager.getAccountLockTime(HONEST), unlockTime, "lock time read by the views");

        // then - deposit block and the last locked second
        _assertLockedViews(HONEST, "deposit block");
        vm.warp(unlockTime - 1);
        _assertLockedViews(HONEST, "last locked second");

        // when - the unlock second, where lockChecks lets the exit through (unlockTime > block.timestamp is false)
        vm.warp(unlockTime);

        // then
        _assertOpenViews(HONEST, "unlock second");
        uint256 maxShares = vault.maxRedeem(HONEST);
        uint256 expectedAssets = vault.previewRedeem(maxShares);
        vm.prank(HONEST);
        uint256 paid = vault.redeem(maxShares, HONEST, HONEST);
        /// @dev With a withdraw fee the rounding of the fee burn can pay one asset unit more (IL-9624 README)
        assertApproxEqAbs(paid, expectedAssets, 1, "redeem(maxRedeem) pays previewRedeem");
        assertGe(paid, expectedAssets, "redeem(maxRedeem) pays at least previewRedeem");
        assertEq(vault.balanceOf(HONEST), 0, "whole position redeemed");
    }

    function testShouldWithdrawMaxWithdrawAtUnlockTime() public {
        // given
        _deposit(HONEST, DEPOSIT);
        uint256 unlockTime = block.timestamp + DELAY;
        vm.warp(unlockTime);

        // when
        uint256 maxAssets = vault.maxWithdraw(HONEST);
        uint256 balanceBefore = usdc.balanceOf(HONEST);
        vm.prank(HONEST);
        vault.withdraw(maxAssets, HONEST, HONEST);

        // then
        assertGt(maxAssets, 0, "maxWithdraw open at the unlock second");
        assertEq(usdc.balanceOf(HONEST) - balanceBefore, maxAssets, "withdraw(maxWithdraw) pays maxWithdraw");
    }

    /// @dev The views do not change the mutators: withdraw and redeem still revert with the lock error from
    ///      `_checkCanCall`, before the limit check, and not with ERC4626ExceededMaxWithdraw / ERC4626ExceededMaxRedeem
    function testShouldRevertWithdrawAndRedeemWithLockErrorWhileMaxViewsAreZero() public {
        // given
        uint256 shares = _deposit(HONEST, DEPOSIT);
        uint256 unlockTime = block.timestamp + DELAY;
        _assertLockedViews(HONEST, "locked");

        // when / then
        vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED, unlockTime));
        vm.prank(HONEST);
        vault.withdraw(1e6, HONEST, HONEST);

        vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED, unlockTime));
        vm.prank(HONEST);
        vault.redeem(shares / 2, HONEST, HONEST);
    }

    /// @dev Most live vaults run with a one-second delay: the views read 0 only in the deposit block
    function testShouldReturnZeroMaxViewsOnlyInDepositBlockWithOneSecondDelay() public {
        // given
        _setDelay(1 seconds);
        _deposit(HONEST, DEPOSIT);

        // then
        _assertLockedViews(HONEST, "deposit block, 1 s delay");
        vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED, block.timestamp + 1));
        vm.prank(HONEST);
        vault.redeem(1, HONEST, HONEST);

        // when
        vm.warp(block.timestamp + 1);

        // then
        _assertOpenViews(HONEST, "next second, 1 s delay");
        uint256 maxShares = vault.maxRedeem(HONEST);
        vm.prank(HONEST);
        vault.redeem(maxShares, HONEST, HONEST);
        assertEq(vault.balanceOf(HONEST), 0, "whole position redeemed");
    }

    function testShouldNeverZeroMaxViewsWithZeroDelay() public {
        // given
        _setDelay(0);
        _deposit(HONEST, DEPOSIT);

        // then - same block as the deposit
        _assertOpenViews(HONEST, "zero delay");
        uint256 maxShares = vault.maxRedeem(HONEST);
        vm.prank(HONEST);
        vault.redeem(maxShares, HONEST, HONEST);
        assertEq(vault.balanceOf(HONEST), 0, "whole position redeemed in the deposit block");
    }

    /// @dev The unlock time is recomputed from the current delay on every read (RedemptionDelayLib.getAccountLockTime),
    ///      so a change of the delay moves the views in both directions, like the mutators
    function testShouldFollowRedemptionDelayChangesInMaxViews() public {
        // given
        _deposit(HONEST, DEPOSIT);
        uint256 depositTime = block.timestamp;
        vm.warp(depositTime + DELAY + 1);
        _assertOpenViews(HONEST, "after the lock");

        // when - the owner raises the delay above the elapsed time
        _setDelay(2 days);

        // then
        _assertLockedViews(HONEST, "relocked by a raised delay");
        vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED, depositTime + 2 days));
        vm.prank(HONEST);
        vault.redeem(1, HONEST, HONEST);

        // when - the owner lowers it to zero
        _setDelay(0);

        // then
        _assertOpenViews(HONEST, "delay lowered to zero");
    }

    /// @dev The views agree with the mutators for any delay and elapsed time: maxRedeem is 0 exactly when redeem
    ///      reverts with the lock error, and redeem(maxRedeem) goes through otherwise
    function testFuzzShouldReturnZeroMaxViewsExactlyWhenRedeemIsLocked(uint256 delay_, uint256 elapsed_) public {
        // given
        delay_ = bound(delay_, 0, 7 days);
        elapsed_ = bound(elapsed_, 0, 8 days);
        _setDelay(delay_);
        _deposit(HONEST, DEPOSIT);
        uint256 unlockTime = block.timestamp + delay_;

        // when
        vm.warp(block.timestamp + elapsed_);

        // then
        if (elapsed_ < delay_) {
            _assertLockedViews(HONEST, "fuzz locked");
            vm.expectRevert(abi.encodeWithSelector(ACCOUNT_IS_LOCKED, unlockTime));
            vm.prank(HONEST);
            vault.redeem(1, HONEST, HONEST);
        } else {
            _assertOpenViews(HONEST, "fuzz open");
            uint256 maxShares = vault.maxRedeem(HONEST);
            vm.prank(HONEST);
            vault.redeem(maxShares, HONEST, HONEST);
            assertEq(vault.balanceOf(HONEST), 0, "fuzz whole position redeemed");
        }
    }

    // ------------------------------------------------------------------ per owner

    function testShouldZeroOnlyTheLockedOwnersMaxViews() public {
        // given
        _deposit(HONEST, DEPOSIT);
        vm.warp(block.timestamp + DELAY + 1);

        // when - another holder deposits now
        _deposit(BYSTANDER, DEPOSIT);

        // then
        _assertOpenViews(HONEST, "unlocked owner");
        _assertLockedViews(BYSTANDER, "fresh depositor");
    }

    /// @dev A third party's deposit to the owner (IL-8736) relocks the owner: the views read 0 for the whole new lock
    function testShouldReturnZeroMaxViewsAfterThirdPartyDustRelock() public {
        // given
        _deposit(HONEST, DEPOSIT);
        vm.warp(block.timestamp + DELAY + 1);
        _assertOpenViews(HONEST, "before the relock");

        // when
        _dustDeposit(HONEST);

        // then
        _assertLockedViews(HONEST, "relocked by dust");
        vm.warp(block.timestamp + DELAY);
        _assertOpenViews(HONEST, "after the new lock");
    }

    /// @dev IL-9705 (Pete D-004): the views know the owner, and so does the lock check: `_checkCanCall` reads the lock
    ///      of the owner of the shares only, so a locked spender can redeem an unlocked owner's shares and
    ///      maxRedeem(owner) is the full balance
    function testShouldNotReflectSpendersLockInOwnersMaxViews() public {
        // given
        uint256 shares = _deposit(HONEST, DEPOSIT);
        vm.warp(block.timestamp + DELAY + 1);
        _deposit(BYSTANDER, DEPOSIT);
        assertGt(accessManager.getAccountLockTime(BYSTANDER), block.timestamp, "spender is locked");
        vm.prank(HONEST);
        vault.approve(BYSTANDER, shares);

        // then
        assertEq(vault.maxRedeem(HONEST), shares, "owner's view is the full balance");

        // when - the spender's own lock does not matter
        vm.prank(BYSTANDER);
        uint256 paid = vault.redeem(shares, BYSTANDER, HONEST);

        // then
        assertGt(paid, 0, "assets paid");
        assertEq(vault.balanceOf(HONEST), 0, "owner's shares redeemed");
    }

    // ------------------------------------------------------------------ exemptions

    function testShouldReturnFullMaxViewsForExemptOwnerDuringLock() public {
        // given
        _exempt(HONEST, true);
        _deposit(HONEST, DEPOSIT);
        assertGt(accessManager.getAccountLockTime(HONEST), block.timestamp, "lock time set for the exempt owner");

        // then - deposit block
        _assertOpenViews(HONEST, "exempt owner");

        // when - the exempt owner leaves in the deposit block
        uint256 maxShares = vault.maxRedeem(HONEST);
        vm.prank(HONEST);
        vault.redeem(maxShares, HONEST, HONEST);

        // then
        assertEq(vault.balanceOf(HONEST), 0, "whole position redeemed in the deposit block");
    }

    function testShouldFollowExemptionChangesInMaxViewsDuringLock() public {
        // given
        _deposit(HONEST, DEPOSIT);
        _assertLockedViews(HONEST, "locked, not exempt");

        // when
        _exempt(HONEST, true);

        // then
        _assertOpenViews(HONEST, "exemption granted during the lock");

        // when
        _exempt(HONEST, false);

        // then
        _assertLockedViews(HONEST, "exemption revoked during the lock");
    }

    /// @dev IL-9634: the factory exempts the fee manager and both fee accounts (granted by hand in this harness).
    ///      A third party's deposit to a fee account starts its lock but leaves its views open
    function testShouldReturnFullMaxViewsForExemptFeeAccountAfterThirdPartyDeposit() public {
        // given
        address feeAccount = PlasmaVaultGovernance(address(vault)).getManagementFeeData().feeAccount;
        address feeManager = FeeAccount(feeAccount).FEE_MANAGER();
        assertEq(feeAccount, FeeManager(feeManager).MANAGEMENT_FEE_ACCOUNT(), "management fee account");
        _exempt(feeAccount, true);

        // when
        _dustDeposit(feeAccount);

        // then
        assertGt(accessManager.getAccountLockTime(feeAccount), block.timestamp, "fee account lock started");
        assertGt(vault.balanceOf(feeAccount), 0, "fee account holds shares");
        _assertOpenViews(feeAccount, "exempt fee account");
    }

    // ------------------------------------------------------------------ redeemFromRequest keeps its lock-free cap

    /// @dev The request path is lock-free by design (IL-8736, IL-9531): it is capped by the owner's balance, not by
    ///      maxRedeem, so a relock that zeroes the views does not hold the request exit
    function testShouldRedeemFromRequestWhileRelockedOwnersMaxViewsAreZero() public {
        // given
        uint256 q = _honestScenario();
        _dustDeposit(HONEST);
        _assertLockedViews(HONEST, "relocked request owner");

        // when
        uint256 balanceBefore = usdc.balanceOf(HONEST);
        vm.prank(HONEST);
        uint256 paid = vault.redeemFromRequest(q, HONEST, HONEST);

        // then
        assertGt(paid, 0, "request paid");
        assertEq(usdc.balanceOf(HONEST) - balanceBefore, paid, "assets received");
        assertEq(wm.getSharesToRelease(), 0, "release consumed");
        _assertLockedViews(HONEST, "still locked for the dust shares");
    }

    /// @dev Dispatcher / parent-vault shaped holder (owner = address(this)): its own top-up locks it, the views read
    ///      0, and the request exit still goes through
    function testShouldRedeemFromRequestForContractHolderWhileMaxViewsAreZero() public {
        // given
        uint256 s = actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 50_000e6));
        vm.warp(block.timestamp + DELAY + 1);
        actor.request(wm, s);
        vm.warp(block.timestamp + 1 hours);
        _release(s);
        actor.deposit(vault, IERC20(address(usdc)), _mintTo(address(actor), 10_000e6));
        _assertLockedViews(address(actor), "holder locked by its own top-up");

        // when
        uint256 paid = actor.redeemFromRequest(vault, s);

        // then
        assertGt(paid, 0, "request paid");
        assertEq(wm.getSharesToRelease(), 0, "release consumed");
    }

    // ------------------------------------------------------------------ helpers

    function _assertLockedViews(address owner_, string memory label_) internal view {
        assertGt(vault.balanceOf(owner_), 0, string.concat(label_, ": owner holds shares"));
        assertEq(vault.maxRedeem(owner_), 0, string.concat(label_, ": maxRedeem is 0 during the lock"));
        assertEq(vault.maxWithdraw(owner_), 0, string.concat(label_, ": maxWithdraw is 0 during the lock"));
    }

    /// @dev Outside the lock: maxRedeem is the balance and maxWithdraw keeps the IL-9624 pricing
    function _assertOpenViews(address owner_, string memory label_) internal view {
        uint256 balance = vault.balanceOf(owner_);
        assertGt(balance, 0, string.concat(label_, ": owner holds shares"));
        assertEq(vault.maxRedeem(owner_), balance, string.concat(label_, ": maxRedeem is the balance"));
        assertEq(
            vault.maxWithdraw(owner_),
            vault.previewRedeem(balance),
            string.concat(label_, ": maxWithdraw is previewRedeem of the balance")
        );
    }

    function _setDelay(uint256 delay_) internal {
        vm.prank(OWNER);
        PlasmaVaultGovernance(address(vault)).setRedemptionDelay(delay_);
    }

    function _exempt(address account_, bool exempt_) internal {
        address[] memory accounts = new address[](1);
        accounts[0] = account_;
        vm.prank(OWNER);
        PlasmaVaultGovernance(address(vault)).setRedemptionDelayExemption(accounts, exempt_);
    }
}
