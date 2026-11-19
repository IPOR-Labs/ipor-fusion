// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemotePlasmaVault, MockPermissiveAuthority} from "../crosschain/mocks/MockRemoteVault.sol";

/// @notice IL-9652 (L21): a request already covered by the last release and still inside its window cannot be
///         overwritten, so the released reserve cannot be left behind by `requestShares(1)`. Expiry and an immediate
///         redeem after the release keep leaving the reserve until the next `releaseFunds` (pinned below).
contract WithdrawManagerReleasedRequestOverwriteTest is Test {
    bytes4 internal constant PENDING = bytes4(keccak256("WithdrawManagerReleasedRequestPending(address,uint256)"));

    address internal constant USER = address(0xA11CE);
    address internal constant OTHER = address(0xB0B);
    uint256 internal constant WINDOW = 1 days;

    MockERC20 internal usdc;
    WithdrawManager internal wm;
    MockRemotePlasmaVault internal vault;

    function setUp() public {
        vm.warp(1_750_000_000);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wm = new WithdrawManager(address(new MockPermissiveAuthority()));
        vault = new MockRemotePlasmaVault(IERC20(address(usdc)), "Vault", "VLT");
        vault.setWithdrawManager(address(wm));
        wm.updatePlasmaVaultAddress(address(vault));
        wm.updateWithdrawWindow(WINDOW);
    }

    function _deposit(address who_, uint256 assets_) internal returns (uint256 shares) {
        usdc.mint(who_, assets_);
        vm.startPrank(who_);
        usdc.approve(address(vault), assets_);
        shares = vault.deposit(assets_, who_);
        vm.stopPrank();
    }

    function _requestAndRelease(uint256 shares_) internal {
        vm.prank(USER);
        wm.requestShares(shares_);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, shares_);
    }

    /// Fails on base: there the overwrite succeeds and the reserve stays.
    function testOverwritingAReleasedRequestReverts() public {
        uint256 shares = _deposit(USER, 100e6);
        _requestAndRelease(shares);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(PENDING, USER, shares));
        wm.requestShares(1);

        assertEq(wm.requestInfo(USER).shares, shares, "request untouched");
        assertEq(wm.getSharesToRelease(), shares, "reserve untouched");
    }

    function testPartiallyRedeemedReleasedRequestStillRefusesOverwrite() public {
        uint256 shares = _deposit(USER, 100e6);
        _requestAndRelease(shares);
        vm.prank(USER);
        vault.redeemFromRequest(shares - 1, USER, USER);

        vm.prank(USER);
        vm.expectRevert(abi.encodeWithSelector(PENDING, USER, 1));
        wm.requestShares(1);
    }

    function testNewRequestWorksAfterTheReleasedOneIsRedeemed() public {
        uint256 shares = _deposit(USER, 100e6);
        _deposit(USER, 100e6);
        _requestAndRelease(shares);
        vm.prank(USER);
        vault.redeemFromRequest(shares, USER, USER);

        vm.prank(USER);
        wm.requestShares(10);
        assertEq(wm.requestInfo(USER).shares, 10);
    }

    function testNewRequestWorksAfterTheWindowEnds() public {
        uint256 shares = _deposit(USER, 100e6);
        _requestAndRelease(shares);
        vm.warp(wm.requestInfo(USER).endWithdrawWindowTimestamp + 1);

        vm.prank(USER);
        wm.requestShares(10);
        assertEq(wm.requestInfo(USER).shares, 10);
    }

    function testRequestNotCoveredByReleaseOverwritesAsBefore() public {
        uint256 shares = _deposit(USER, 100e6);
        _requestAndRelease(shares);
        // filed after the release timestamp, so the release does not cover it
        _deposit(OTHER, 100e6);
        vm.prank(OTHER);
        wm.requestShares(5);

        vm.prank(OTHER);
        wm.requestShares(7);
        assertEq(wm.requestInfo(OTHER).shares, 7, "unreleased request is replaced");
    }

    function testRequestWithNoReleaseOverwritesAsBefore() public {
        uint256 shares = _deposit(USER, 100e6);
        vm.prank(USER);
        wm.requestShares(shares);
        vm.prank(USER);
        wm.requestShares(1);
        assertEq(wm.requestInfo(USER).shares, 1);
    }

    /// Pinning: after the window ends the reserve stays (no per-request ledger) until the next releaseFunds rewrites it.
    function testReserveOfAnExpiredRequestStaysUntilNextRelease() public {
        uint256 shares = _deposit(USER, 100e6);
        _requestAndRelease(shares);
        vm.warp(wm.requestInfo(USER).endWithdrawWindowTimestamp + 1);
        vm.prank(USER);
        wm.requestShares(1);
        assertEq(wm.getSharesToRelease(), shares, "reserve of the expired request stays");

        wm.releaseFunds(block.timestamp - 1, 0);
        assertEq(wm.getSharesToRelease(), 0, "next release overwrites it");
    }
}
