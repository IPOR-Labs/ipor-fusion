// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {PlasmaVaultPauser} from "../../contracts/managers/pause/PlasmaVaultPauser.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

/// @dev Fork test on Base mainnet against the PRODUCTION IPOR USDC Lending Optimizer vault - a LEGACY vault:
/// its access manager is a non-upgradeable clone deployed long before IL-7725 and maps `updateTargetClosed`
/// to GUARDIAN_ROLE. The PlasmaVaultPauser calls exactly that function (with closed=true hard-coded), so the
/// only integration step is the DAO Safe granting GUARDIAN_ROLE to the pauser contract - no access manager
/// change or redeploy. This test pins the e2e on the live vault: whitelisted key pauses, deposits are blocked,
/// a human guardian reopens.
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

        vm.prank(owner);
        pauser.addToWhitelist(VAULT, guardian);
    }

    function testShouldPauseLegacyProductionVaultAndGuardianReopen() public {
        // given - the DAO Safe grants GUARDIAN_ROLE to the pauser contract, exactly like to a human guardian
        vm.prank(DAO_SAFE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, address(pauser), 0);
        (bool isMember, ) = accessManager.hasRole(Roles.GUARDIAN_ROLE, address(pauser));
        assertTrue(isMember, "pauser holds GUARDIAN_ROLE");

        address humanGuardian = makeAddr("humanGuardian");
        vm.prank(DAO_SAFE);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, humanGuardian, 0);

        deal(USDC, user, 2 * DEPOSIT_AMOUNT);
        vm.startPrank(user);
        IERC20(USDC).approve(VAULT, 2 * DEPOSIT_AMOUNT);
        uint256 shares = PlasmaVault(VAULT).deposit(DEPOSIT_AMOUNT, user);
        vm.stopPrank();
        assertGt(shares, 0, "deposit should work before pause");
        assertFalse(accessManager.isTargetClosed(VAULT), "vault should be open before pause");

        // when - the whitelisted emergency key pauses through the pauser contract
        vm.expectEmit(true, true, true, true);
        emit PlasmaVaultPauser.VaultPaused(VAULT, ACCESS_MANAGER, guardian);
        vm.prank(guardian);
        pauser.pause(VAULT);

        // then - the legacy production vault is closed and deposits are blocked
        assertTrue(accessManager.isTargetClosed(VAULT), "legacy vault paused by the pauser contract");
        assertFalse(pauser.isWhitelisted(VAULT, guardian), "one-shot entry consumed");
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, user));
        vm.prank(user);
        PlasmaVault(VAULT).deposit(DEPOSIT_AMOUNT, user);

        // and - the consumed key cannot pause again
        vm.expectRevert(abi.encodeWithSelector(PlasmaVaultPauser.AccountNotWhitelisted.selector, VAULT, guardian));
        vm.prank(guardian);
        pauser.pause(VAULT);

        // when - a human guardian reopens directly on the access manager
        vm.prank(humanGuardian);
        accessManager.updateTargetClosed(VAULT, false);

        // then - deposits work again
        assertFalse(accessManager.isTargetClosed(VAULT), "vault should be reopened");
        vm.prank(user);
        assertGt(PlasmaVault(VAULT).deposit(DEPOSIT_AMOUNT, user), 0, "deposit should work after reopening");
    }

    function testShouldNotPauseLegacyProductionVaultWithoutGuardianRole() public {
        // when / then - the pauser contract was never granted GUARDIAN_ROLE on the legacy access manager
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, address(pauser)));
        vm.prank(guardian);
        pauser.pause(VAULT);

        assertFalse(accessManager.isTargetClosed(VAULT), "vault should stay open");
        assertTrue(pauser.isWhitelisted(VAULT, guardian), "one-shot entry kept on revert");
    }
}
