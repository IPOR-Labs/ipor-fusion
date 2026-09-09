// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {PlasmaVaultPauser} from "../../contracts/managers/pause/PlasmaVaultPauser.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev Fork e2e on Base mainnet against the PRODUCTION IPOR USDC Lending Optimizer vault.
/// The pauser is wired exactly as it would be in production: the OWNER_ROLE holder (DAO Safe,
/// admin of GUARDIAN_ROLE, execution delay 0) grants GUARDIAN_ROLE to the pauser contract.
/// Verified live at FORK_BLOCK: getRoleAdmin(GUARDIAN_ROLE) == OWNER_ROLE,
/// getMinimalExecutionDelayForRole(GUARDIAN_ROLE) == 0, deposit mapped to PUBLIC_ROLE,
/// REDEMPTION_DELAY_IN_SECONDS == 1.
contract PlasmaVaultPauserForkTest is Test {
    /// @dev IPOR Fusion USDC Lending Optimizer (Base mainnet)
    address internal constant VAULT = 0x45aa96f0b3188D47a1DaFdbefCE1db6B37f58216;
    address internal constant ACCESS_MANAGER = 0x051F90A809d8Bf16e61514F8035C8bc644508a81;
    /// @dev DAO Safe - holds OWNER_ROLE (the admin role of GUARDIAN_ROLE) with execution delay 0
    address internal constant DAO_SAFE = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;
    /// @dev Vault underlying - native Circle USDC on Base
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    uint256 internal constant FORK_BLOCK = 49_875_613;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    PlasmaVaultPauser internal pauser;
    IporFusionAccessManager internal accessManager;

    address internal owner;
    address internal guardian;
    address internal user;

    function setUp() public {
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), FORK_BLOCK);

        accessManager = IporFusionAccessManager(ACCESS_MANAGER);

        owner = makeAddr("owner");
        guardian = makeAddr("guardian");
        user = makeAddr("user");

        pauser = new PlasmaVaultPauser(owner);

        /// @dev production wiring: the OWNER_ROLE holder grants GUARDIAN_ROLE to the pauser contract
        vm.prank(DAO_SAFE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, address(pauser), 0);

        (bool isMember, uint32 executionDelay) = accessManager.hasRole(Roles.GUARDIAN_ROLE, address(pauser));
        assertTrue(isMember, "pauser should have GUARDIAN_ROLE");
        assertEq(executionDelay, 0, "pauser should act without execution delay");

        vm.prank(owner);
        pauser.addToWhitelist(VAULT, guardian);
    }

    function testShouldPauseProductionVaultOnBaseFork() public {
        // given - the production vault is open, deposit and redeem work
        assertFalse(accessManager.isTargetClosed(VAULT), "vault should be open before pause");

        deal(USDC, user, 2 * DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(USDC).approve(VAULT, 2 * DEPOSIT_AMOUNT);
        uint256 shares = PlasmaVault(VAULT).deposit(2 * DEPOSIT_AMOUNT, user);
        vm.stopPrank();
        assertGt(shares, 0, "deposit should work before pause");

        /// @dev skip the 1-second redemption delay of this vault
        vm.warp(block.timestamp + 2);

        vm.prank(user);
        PlasmaVault(VAULT).redeem(shares / 2, user, user);
        assertGt(IERC20(USDC).balanceOf(user), 0, "redeem should work before pause");

        // when
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.VaultPaused(VAULT, ACCESS_MANAGER, guardian);
        vm.prank(guardian);
        pauser.pause(VAULT);

        // then - the vault is closed on its access manager...
        assertTrue(accessManager.isTargetClosed(VAULT), "vault should be closed after pause");

        // ...deposits are blocked...
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user));
        vm.prank(user);
        PlasmaVault(VAULT).deposit(DEPOSIT_AMOUNT, user);

        // ...and redemptions are blocked as well
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user));
        vm.prank(user);
        PlasmaVault(VAULT).redeem(shares / 2, user, user);
    }

    function testShouldNotPauseProductionVaultWhenNotWhitelisted() public {
        // when / then
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, VAULT, user));
        vm.prank(user);
        pauser.pause(VAULT);

        assertFalse(accessManager.isTargetClosed(VAULT), "vault should stay open");
    }

    function testShouldNotPauseProductionVaultWhenPauserHasNoGuardianRole() public {
        // given - a pauser which was never granted GUARDIAN_ROLE on the production access manager
        vm.startPrank(owner);
        PlasmaVaultPauser pauserWithoutRole = new PlasmaVaultPauser(owner);
        pauserWithoutRole.addToWhitelist(VAULT, guardian);
        vm.stopPrank();

        // when / then
        vm.expectRevert(
            abi.encodeWithSelector(
                IporFusionAccessManager.AccessManagedUnauthorized.selector,
                address(pauserWithoutRole)
            )
        );
        vm.prank(guardian);
        pauserWithoutRole.pause(VAULT);

        assertFalse(accessManager.isTargetClosed(VAULT), "vault should stay open");
    }

    function testShouldGuardianReopenProductionVaultAfterPause() public {
        // given
        vm.prank(guardian);
        pauser.pause(VAULT);
        assertTrue(accessManager.isTargetClosed(VAULT), "vault should be closed after pause");

        address humanGuardian = makeAddr("humanGuardian");
        vm.prank(DAO_SAFE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, humanGuardian, 0);

        // when - reopening happens directly on the access manager, the pauser cannot do it
        vm.prank(humanGuardian);
        accessManager.updateTargetClosed(VAULT, false);

        // then - the vault is open and accepts deposits again
        assertFalse(accessManager.isTargetClosed(VAULT), "vault should be reopened by the guardian");

        deal(USDC, user, DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(USDC).approve(VAULT, DEPOSIT_AMOUNT);
        uint256 shares = PlasmaVault(VAULT).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
        assertGt(shares, 0, "deposit should work after reopening");
    }
}
