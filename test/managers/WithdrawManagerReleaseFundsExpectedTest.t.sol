// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemotePlasmaVault, MockPermissiveAuthority} from "../crosschain/mocks/MockRemoteVault.sol";

/// @notice IL-9653 (L22): `releaseFunds(timestamp, sharesToRelease, expectedSharesToRelease)` reverts when a
///         `redeemFromRequest` between the keeper's read and its transaction changed the reserve; the two-argument
///         overload keeps overwriting unconditionally. Calls go through signatures, so the file also compiles on base.
contract WithdrawManagerReleaseFundsExpectedTest is Test {
    bytes4 internal constant EXCEED_SUPPLY =
        bytes4(keccak256("WithdrawManagerSharesToReleaseExceedSupply(uint256,uint256)"));
    bytes4 internal constant CHANGED = bytes4(keccak256("WithdrawManagerSharesToReleaseChanged(uint256,uint256)"));

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

    function _release3(uint256 ts_, uint256 shares_, uint256 expected_) internal returns (bool ok) {
        (ok, ) = address(wm).call(
            abi.encodeWithSignature("releaseFunds(uint256,uint256,uint256)", ts_, shares_, expected_)
        );
    }

    /// Race: the keeper reads the reserve, a user redeems, the keeper's transaction lands.
    function _raceSetup() internal returns (uint256 shares, uint256 read, uint256 redeemed) {
        shares = _deposit(USER, 100e6);
        vm.prank(USER);
        wm.requestShares(shares);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, shares);
        read = wm.getSharesToRelease();

        redeemed = shares / 4;
        vm.prank(USER);
        vault.redeemFromRequest(redeemed, USER, USER);
    }

    /// Fails on base: the three-argument overload does not exist there.
    function testExpectedValueMismatchRevertsAfterARace() public {
        (uint256 shares, uint256 read, uint256 redeemed) = _raceSetup();
        (bool ok, bytes memory ret) = address(wm).call(
            abi.encodeWithSignature(
                "releaseFunds(uint256,uint256,uint256)",
                block.timestamp - 1,
                shares - redeemed,
                read
            )
        );
        assertFalse(ok);
        assertEq(bytes4(ret), CHANGED);
        assertEq(ret.length, 68);
        assertEq(wm.getSharesToRelease(), shares - redeemed, "reserve not overwritten");
    }

    function testExpectedValueMatchingReleases() public {
        uint256 shares = _deposit(USER, 100e6);
        assertEq(wm.getSharesToRelease(), 0);
        vm.warp(block.timestamp + 2);
        assertTrue(_release3(block.timestamp - 1, shares, 0), "no race: accepted");
        assertEq(wm.getSharesToRelease(), shares);
        assertEq(wm.getLastReleaseFundsTimestamp(), block.timestamp - 1);

        assertTrue(_release3(block.timestamp - 1, shares / 2, shares), "second release with the value just read");
        assertEq(wm.getSharesToRelease(), shares / 2);
    }

    /// Pinning of base behaviour: the two-argument overload overwrites in the same race.
    function testLegacyOverloadStillOverwritesInTheSameRace() public {
        (uint256 shares, , uint256 redeemed) = _raceSetup();
        assertEq(wm.getSharesToRelease(), shares - redeemed);
        // redeeming burned shares; new deposits keep the supply above the overwrite value (IL-9604 bound)
        _deposit(OTHER, 100e6);
        wm.releaseFunds(block.timestamp - 1, shares);
        assertEq(wm.getSharesToRelease(), shares, "absolute overwrite (reserved a second time)");
    }

    function testExpectedValueOverloadKeepsTheTimestampCheck() public {
        _deposit(USER, 100e6);
        (bool ok, ) = address(wm).call(
            abi.encodeWithSignature("releaseFunds(uint256,uint256,uint256)", block.timestamp + 1, 1, 0)
        );
        assertFalse(ok, "future timestamp refused");
    }

    function testExpectedValueOverloadAppliesTheSupplyBound() public {
        uint256 supply = _deposit(USER, 100e6);
        vm.warp(block.timestamp + 2);
        (bool ok, bytes memory ret) = address(wm).call(
            abi.encodeWithSignature("releaseFunds(uint256,uint256,uint256)", block.timestamp - 1, supply + 1, 0)
        );
        assertFalse(ok);
        assertEq(bytes4(ret), EXCEED_SUPPLY);
    }
}
