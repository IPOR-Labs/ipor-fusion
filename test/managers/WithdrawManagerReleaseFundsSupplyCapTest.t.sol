// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {MockRemotePlasmaVault, MockPermissiveAuthority} from "../crosschain/mocks/MockRemoteVault.sol";

/// @notice IL-9604 (M14): `releaseFunds` refuses a reserve above the vault's total supply (a sanity bound; ALPHA can
///         still reserve the whole supply). Written against symbols that exist on base 8692fbe5 (selectors only).
contract WithdrawManagerReleaseFundsSupplyCapTest is Test {
    bytes4 internal constant EXCEED_SUPPLY =
        bytes4(keccak256("WithdrawManagerSharesToReleaseExceedSupply(uint256,uint256)"));

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

    function testReleaseAboveTotalSupplyReverts() public {
        uint256 supply = _deposit(USER, 100e6);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(EXCEED_SUPPLY, supply + 1, supply));
        wm.releaseFunds(block.timestamp - 1, supply + 1);
        assertEq(wm.getSharesToRelease(), 0, "nothing reserved");
    }

    function testReleaseOfTypeUint128MaxReverts() public {
        uint256 supply = _deposit(USER, 100e6);
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(EXCEED_SUPPLY, uint256(type(uint128).max), supply));
        wm.releaseFunds(block.timestamp - 1, type(uint128).max);
    }

    function testReleaseOfTotalSupplyIsAccepted() public {
        uint256 supply = _deposit(USER, 100e6);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, supply);
        assertEq(wm.getSharesToRelease(), supply, "whole supply may be reserved");
    }

    function testTypicalReleaseUnchanged() public {
        uint256 supply = _deposit(USER, 100e6);
        _deposit(OTHER, 50e6);
        vm.warp(block.timestamp + 2);
        wm.releaseFunds(block.timestamp - 1, supply / 2);
        assertEq(wm.getSharesToRelease(), supply / 2);
        assertEq(wm.getLastReleaseFundsTimestamp(), block.timestamp - 1);
    }

    /// Pinning: a manager not wired to its vault has no supply to compare with, so the bound is skipped.
    function testReleaseOnUnwiredManagerSkipsTheBound() public {
        WithdrawManager unwired = new WithdrawManager(address(new MockPermissiveAuthority()));
        vm.warp(block.timestamp + 2);
        unwired.releaseFunds(block.timestamp - 1, 1e30);
        assertEq(unwired.getSharesToRelease(), 1e30);
    }
}
