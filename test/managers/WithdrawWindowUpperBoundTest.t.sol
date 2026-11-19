// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemotePlasmaVault} from "../crosschain/mocks/MockRemoteVault.sol";

/// @dev Access manager that allows every call and reports no account lock
contract UpperBoundAllowAllAuthority {
    function canCall(address, address, bytes4) external pure returns (bool immediate, uint32 delay) {
        return (true, 0);
    }

    function getAccountLockTime(address) external pure returns (uint256) {
        return 0;
    }

    function isRedemptionDelayExempt(address) external pure returns (bool) {
        return false;
    }
}

/// @notice IL-9675: the withdraw window length has an upper bound of 365 days, enforced when it is set
contract WithdrawWindowUpperBoundTest is Test {
    uint256 internal constant MAX_WINDOW = 365 days;
    address internal constant USER = address(0xA11CE);

    MockERC20 internal usdc;
    WithdrawManager internal wm;
    MockRemotePlasmaVault internal vault;

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wm = new WithdrawManager(address(new UpperBoundAllowAllAuthority()));
        vault = new MockRemotePlasmaVault(IERC20(address(usdc)), "Vault", "VLT");
        vault.setWithdrawManager(address(wm));
        wm.updatePlasmaVaultAddress(address(vault));
    }

    function testShouldRevertWhenWindowAboveMaximum() public {
        vm.expectRevert(
            abi.encodeWithSignature("WithdrawWindowLengthAboveMaximum(uint256,uint256)", MAX_WINDOW + 1, MAX_WINDOW)
        );
        wm.updateWithdrawWindow(MAX_WINDOW + 1);
    }

    function testShouldRevertWhenWindowIsHugeAndKeepPreviousValue() public {
        wm.updateWithdrawWindow(1 days);
        vm.expectRevert(
            abi.encodeWithSignature("WithdrawWindowLengthAboveMaximum(uint256,uint256)", type(uint256).max, MAX_WINDOW)
        );
        wm.updateWithdrawWindow(type(uint256).max);
        assertEq(wm.getWithdrawWindow(), 1 days, "window unchanged after the revert");
    }

    function testShouldAcceptWindowEqualToMaximumAndRequestSharesWorks() public {
        wm.updateWithdrawWindow(MAX_WINDOW);
        assertEq(wm.getWithdrawWindow(), MAX_WINDOW, "boundary is inclusive");

        usdc.mint(USER, 100e6);
        vm.startPrank(USER);
        usdc.approve(address(vault), 100e6);
        uint256 shares = vault.deposit(100e6, USER);
        wm.requestShares(shares);
        vm.stopPrank();

        assertEq(
            wm.requestInfo(USER).endWithdrawWindowTimestamp,
            block.timestamp + MAX_WINDOW,
            "request at max window"
        );
    }

    function testShouldStillRejectZeroWindow() public {
        vm.expectRevert(abi.encodeWithSignature("WithdrawWindowLengthCannotBeZero()"));
        wm.updateWithdrawWindow(0);
    }
}
