// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {MockERC20} from "../../test_helpers/MockERC20.sol";
import {MockRemotePlasmaVault} from "../../crosschain/mocks/MockRemoteVault.sol";

/// @dev Access manager of a vault deployed before the redemption-delay exemptions (IL-7935): it allows every call and
///      answers getAccountLockTime, but has no isRedemptionDelayExempt
contract LegacyLockAuthority {
    mapping(address account => uint256 lockTime) private _lockTimes;

    function canCall(address, address, bytes4) external pure returns (bool immediate, uint32 delay) {
        return (true, 0);
    }

    function setAccountLockTime(address account_, uint256 lockTime_) external {
        _lockTimes[account_] = lockTime_;
    }

    function getAccountLockTime(address account_) external view returns (uint256) {
        return _lockTimes[account_];
    }
}

/// @notice IL-9531: the WithdrawManager on a vault deployed before IL-9531, which can get it through
///         UpdateWithdrawManagerMaintenanceFuse. The vault has no request caps, so the WithdrawManager keeps the balance
///         check and the lock at filing, and skips the cap.
contract WithdrawManagerLegacyVaultTest is Test {
    bytes4 internal constant NOT_BACKED = bytes4(keccak256("WithdrawManagerRequestNotBacked(address,uint256,uint256)"));

    address internal constant USER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    uint256 internal constant WINDOW = 1 days;

    MockERC20 internal usdc;
    LegacyLockAuthority internal authority;
    WithdrawManager internal wm;
    MockRemotePlasmaVault internal vault;

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        authority = new LegacyLockAuthority();
        wm = new WithdrawManager(address(authority));
        vault = new MockRemotePlasmaVault(IERC20(address(usdc)), "Legacy Vault", "LGC");
        vault.setWithdrawManager(address(wm));
        vault.disableRequestCaps();
        wm.updatePlasmaVaultAddress(address(vault));
        wm.updateWithdrawWindow(WINDOW);
    }

    function testProbeSeesVaultWithoutRequestCaps() public view {
        assertFalse(wm.vaultKeepsRequestCaps());
    }

    function testProbeSeesVaultWithRequestCaps() public {
        WithdrawManager other = new WithdrawManager(address(authority));
        MockRemotePlasmaVault capsVault = new MockRemotePlasmaVault(IERC20(address(usdc)), "New Vault", "NEW");
        capsVault.setWithdrawManager(address(other));
        other.updatePlasmaVaultAddress(address(capsVault));
        assertTrue(other.vaultKeepsRequestCaps());
    }

    function testBalanceCheckedAtFiling() public {
        uint256 shares = _deposit(USER, 100e6);
        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(NOT_BACKED, USER, shares, shares + 1));
        wm.requestShares(shares + 1);
    }

    /// The vault has no setRequestCap / getRequestCap (the mock reverts if they are called): request and exit work.
    function testRequestAndExitWithoutCapCalls() public {
        uint256 shares = _deposit(USER, 100e6);
        vm.prank(USER);
        wm.requestShares(shares);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, shares);
        vm.prank(USER);
        vault.redeemFromRequest(shares, USER, USER);
        assertEq(usdc.balanceOf(USER), 100e6);
    }

    /// The lock at filing works with an access manager that has no isRedemptionDelayExempt (before IL-7935).
    function testLockAtFilingWithAccessManagerWithoutExemptions() public {
        uint256 shares = _deposit(USER, 100e6);
        uint256 lockEnd = block.timestamp + 1 days;
        authority.setAccountLockTime(USER, lockEnd);
        vm.prank(USER);
        wm.requestShares(shares);
        assertEq(wm.requestInfo(USER).endWithdrawWindowTimestamp, lockEnd + WINDOW, "starts at the lock end");

        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, shares);
        vm.prank(USER);
        vm.expectRevert(bytes("cannot withdraw from request"));
        vault.redeemFromRequest(shares, USER, USER);

        vm.warp(lockEnd + 2);
        wm.releaseFunds(block.timestamp - 1, shares);
        vm.prank(USER);
        vault.redeemFromRequest(shares, USER, USER);
    }

    /// Known gap without caps: shares moved away after the request and brought back before the redeem still redeem it.
    function testKnownGapSharesBroughtBackAfterRequestStillRedeem() public {
        uint256 shares = _deposit(USER, 100e6);
        vm.prank(USER);
        wm.requestShares(shares);
        vm.prank(USER);
        vault.transfer(OTHER, shares);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, shares);
        _deposit(USER, 100e6);
        vm.prank(USER);
        vault.redeemFromRequest(shares, USER, USER);
    }

    function _deposit(address who_, uint256 assets_) internal returns (uint256 shares) {
        usdc.mint(who_, assets_);
        vm.startPrank(who_);
        usdc.approve(address(vault), assets_);
        shares = vault.deposit(assets_, who_);
        vm.stopPrank();
    }
}
