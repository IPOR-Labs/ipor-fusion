// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {WhitelistWrappedPlasmaVault} from "../../../contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";

contract WhitelistWrappedPlasmaVaultAccessTest is Test {
    WhitelistWrappedPlasmaVault public wPlasmaVault;

    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    PlasmaVault public constant plasmaVault = PlasmaVault(0x43Ee0243eA8CF02f7087d8B16C8D2007CC9c7cA2);

    address public admin;
    address public manager;
    address public user;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21621506);

        admin = makeAddr("admin");
        manager = makeAddr("manager");
        user = makeAddr("user");

        wPlasmaVault = new WhitelistWrappedPlasmaVault(
            "Wrapped USDC",
            "wFusionUSDC",
            address(plasmaVault),
            admin,
            admin,
            0,
            admin,
            0
        );
    }

    function testRoleAdminsAreConfigured() public {
        bytes32 defaultAdmin = wPlasmaVault.DEFAULT_ADMIN_ROLE();
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        assertEq(
            wPlasmaVault.getRoleAdmin(whitelistManager),
            defaultAdmin,
            "WHITELIST_MANAGER admin must be DEFAULT_ADMIN_ROLE"
        );
        assertEq(
            wPlasmaVault.getRoleAdmin(whitelisted),
            whitelistManager,
            "WHITELISTED admin must be WHITELIST_MANAGER"
        );
    }

    function testDefaultAdminCanGrantWhitelistManager() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();

        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);

        assertTrue(wPlasmaVault.hasRole(whitelistManager, manager), "manager should have WHITELIST_MANAGER role");
    }

    function testWhitelistManagerCanGrantWhitelisted() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);

        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        assertTrue(wPlasmaVault.hasRole(whitelisted, user), "user should have WHITELISTED role");
    }

    function testNonAdminCannotGrantDefaultAdminRole() public {
        bytes32 defaultAdmin = wPlasmaVault.DEFAULT_ADMIN_ROLE();
        address attacker = makeAddr("attacker");
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, defaultAdmin)
        );
        wPlasmaVault.grantRole(defaultAdmin, newAdmin);
        vm.stopPrank();

        assertFalse(wPlasmaVault.hasRole(defaultAdmin, newAdmin), "newAdmin should not gain DEFAULT_ADMIN_ROLE");
    }

    function testAdminCanGrantSecondDefaultAdminRole() public {
        bytes32 defaultAdmin = wPlasmaVault.DEFAULT_ADMIN_ROLE();
        address secondAdmin = makeAddr("secondAdmin");

        // admin grants DEFAULT_ADMIN_ROLE to secondAdmin
        vm.prank(admin);
        wPlasmaVault.grantRole(defaultAdmin, secondAdmin);

        // verify secondAdmin has DEFAULT_ADMIN_ROLE
        assertTrue(wPlasmaVault.hasRole(defaultAdmin, secondAdmin), "secondAdmin should gain DEFAULT_ADMIN_ROLE");
    }

    function testNonAdminCannotGrantWhitelistManager() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 defaultAdmin = wPlasmaVault.DEFAULT_ADMIN_ROLE();
        address attacker = makeAddr("attacker2");
        address newManager = makeAddr("newManager");

        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, defaultAdmin)
        );
        wPlasmaVault.grantRole(whitelistManager, newManager);
        vm.stopPrank();

        assertFalse(wPlasmaVault.hasRole(whitelistManager, newManager), "newManager should not gain WHITELIST_MANAGER");
    }
}
