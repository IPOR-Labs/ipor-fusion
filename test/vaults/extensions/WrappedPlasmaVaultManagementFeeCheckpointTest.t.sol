// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WrappedPlasmaVault} from "../../../contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {WhitelistWrappedPlasmaVault} from "../../../contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol";
import {WrappedPlasmaVaultBase} from "../../../contracts/vaults/extensions/WrappedPlasmaVaultBase.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title WrappedPlasmaVaultManagementFeeCheckpointTest
/// @notice IL-9591: configureManagementFee must settle the accrual at the old rate and restart the accrual clock,
///         so a rate change never applies retroactively. Covers both wrappers.
contract WrappedPlasmaVaultManagementFeeCheckpointTest is Test {
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public constant PLASMA_VAULT = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);

    uint256 public constant DEPOSIT = 1_000_000e6;

    address public admin;
    address public user;
    address public feeRecipient;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21621506);
        admin = makeAddr("admin");
        user = makeAddr("user");
        feeRecipient = makeAddr("feeRecipient");
        deal(USDC, user, DEPOSIT * 4);
    }

    function _deployPlain(uint256 feeBps_) internal returns (WrappedPlasmaVaultBase vault_) {
        WrappedPlasmaVault v = new WrappedPlasmaVault(
            "Wrapped",
            "w",
            address(PLASMA_VAULT),
            admin,
            feeRecipient,
            feeBps_,
            admin,
            0
        );
        vault_ = WrappedPlasmaVaultBase(address(v));
    }

    function _deployWhitelist(uint256 feeBps_) internal returns (WrappedPlasmaVaultBase vault_) {
        WhitelistWrappedPlasmaVault v = new WhitelistWrappedPlasmaVault(
            "Wrapped",
            "w",
            address(PLASMA_VAULT),
            admin,
            feeRecipient,
            feeBps_,
            admin,
            0
        );
        vm.startPrank(admin);
        v.grantRole(v.WHITELIST_MANAGER(), admin);
        v.grantRole(v.WHITELISTED(), user);
        vm.stopPrank();
        vault_ = WrappedPlasmaVaultBase(address(v));
    }

    function _deposit(WrappedPlasmaVaultBase vault_) internal {
        vm.startPrank(user);
        IERC20(USDC).approve(address(vault_), type(uint256).max);
        vault_.deposit(DEPOSIT, user);
        vm.stopPrank();
    }

    function _configure(bool whitelist_, WrappedPlasmaVaultBase vault_, uint256 feeBps_) internal {
        vm.prank(admin);
        if (whitelist_) {
            WhitelistWrappedPlasmaVault(address(vault_)).configureManagementFee(feeRecipient, feeBps_);
        } else {
            WrappedPlasmaVault(address(vault_)).configureManagementFee(feeRecipient, feeBps_);
        }
    }

    // ---- (1) 0% for a year, then a raise to 5%: the past year must not be charged ----

    function testPlainRaiseFromZeroDoesNotChargePast() public {
        _raiseFromZero(false, _deployPlain(0));
    }

    function testWhitelistRaiseFromZeroDoesNotChargePast() public {
        _raiseFromZero(true, _deployWhitelist(0));
    }

    function _raiseFromZero(bool whitelist_, WrappedPlasmaVaultBase vault_) internal {
        _deposit(vault_);
        vm.warp(block.timestamp + 365 days);

        _configure(whitelist_, vault_, 500);

        assertEq(vault_.balanceOf(feeRecipient), 0, "no mint right after the raise");
        assertEq(vault_.getManagementFeeData().lastUpdateTimestamp, block.timestamp, "clock restarted at the change");

        vault_.realizeFees();
        assertEq(vault_.balanceOf(feeRecipient), 0, "the 0% year must not be charged at 5%");

        // the new rate applies from the change on
        vm.warp(block.timestamp + 365 days);
        vault_.realizeFees();
        assertGt(vault_.balanceOf(feeRecipient), 0, "fee accrues at the new rate going forward");
    }

    // ---- (2) 1% -> 5%: the elapsed period is charged at 1% ----

    function testPlainRateChangeSettlesAtOldRate() public {
        _changeRate(false, _deployPlain(100));
    }

    function testWhitelistRateChangeSettlesAtOldRate() public {
        _changeRate(true, _deployWhitelist(100));
    }

    function _changeRate(bool whitelist_, WrappedPlasmaVaultBase vault_) internal {
        _deposit(vault_);
        vm.warp(block.timestamp + 365 days);

        _configure(whitelist_, vault_, 500);

        uint256 minted = vault_.balanceOf(feeRecipient);
        assertGt(minted, 0, "old-rate accrual minted at the change");
        uint256 mintedValue = vault_.convertToAssets(minted);
        // about 1% of ~1,000,000 USDC; far below the 5% a retroactive change would charge
        assertGt(mintedValue, 9_000e6, "settled at the old 1% rate (lower bound)");
        assertLt(mintedValue, 11_000e6, "settled at the old 1% rate (upper bound)");

        vault_.realizeFees();
        assertEq(vault_.balanceOf(feeRecipient), minted, "nothing more is owed for the settled period");
    }
}
