// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {WhitelistWrappedPlasmaVault} from "../../../contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    function testNonManagerCannotGrantWhitelisted() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();
        address attacker = makeAddr("attacker3");
        address newWhitelisted = makeAddr("newWhitelisted");

        // attacker has neither DEFAULT_ADMIN_ROLE nor WHITELIST_MANAGER
        vm.startPrank(attacker);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, whitelistManager)
        );
        wPlasmaVault.grantRole(whitelisted, newWhitelisted);
        vm.stopPrank();

        assertFalse(wPlasmaVault.hasRole(whitelisted, newWhitelisted), "newWhitelisted should not gain WHITELISTED");
    }

    function testWhitelistedUserCanDeposit() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        // grant roles: admin -> manager (WHITELIST_MANAGER), manager -> user (WHITELISTED)
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        // fund user with USDC and approve vault
        uint256 assets = 1_000e6; // 1,000 USDC
        deal(USDC, user, assets);
        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), assets);

        uint256 shares = wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        assertGt(shares, 0, "deposit should mint shares");
        assertEq(wPlasmaVault.balanceOf(user), shares, "user balance should equal minted shares");
    }

    function testWhitelistedUserCanMint() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        // grant roles
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        // choose shares and fund user sufficiently, approve
        uint256 sharesToMint = 1e9; // modest amount of shares
        deal(USDC, user, 1_000_000e6);
        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), type(uint256).max);

        uint256 assetsSpent = wPlasmaVault.mint(sharesToMint, user);
        vm.stopPrank();

        assertGt(assetsSpent, 0, "mint should spend assets");
        assertEq(wPlasmaVault.balanceOf(user), sharesToMint, "user should receive requested shares");
    }

    function testNonWhitelistedCannotDeposit() public {
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();
        address attacker = makeAddr("attacker4");

        uint256 assets = 1_000e6;
        deal(USDC, attacker, assets);

        vm.startPrank(attacker);
        IERC20(USDC).approve(address(wPlasmaVault), assets);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, whitelisted)
        );
        wPlasmaVault.deposit(assets, attacker);
        vm.stopPrank();
    }

    function testNonWhitelistedCannotMint() public {
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();
        address attacker = makeAddr("attacker5");

        uint256 sharesToMint = 1e9;
        deal(USDC, attacker, 1_000_000e6);

        vm.startPrank(attacker);
        IERC20(USDC).approve(address(wPlasmaVault), type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", attacker, whitelisted)
        );
        wPlasmaVault.mint(sharesToMint, attacker);
        vm.stopPrank();
    }

    function testWhitelistedUserCanWithdraw() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        // grant roles and deposit first
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        uint256 assets = 10_000e6;
        deal(USDC, user, assets);

        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), assets);
        wPlasmaVault.deposit(assets, user);

        vm.warp(block.timestamp + 10);

        uint256 userUsdcBefore = IERC20(USDC).balanceOf(user);
        uint256 userSharesBefore = wPlasmaVault.balanceOf(user);

        uint256 toWithdraw = assets / 2;
        uint256 sharesBurned = wPlasmaVault.withdraw(toWithdraw, user, user);
        vm.stopPrank();

        assertGt(sharesBurned, 0, "withdraw should burn shares");
        assertLt(wPlasmaVault.balanceOf(user), userSharesBefore, "shares should decrease");
        assertGt(IERC20(USDC).balanceOf(user), userUsdcBefore, "USDC balance should increase");
    }

    function testWhitelistedUserCanRedeem() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        // grant roles and deposit first
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        uint256 assets = 10_000e6;
        deal(USDC, user, assets);

        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), assets);
        wPlasmaVault.deposit(assets, user);

        vm.warp(block.timestamp + 10);

        uint256 userShares = wPlasmaVault.balanceOf(user);
        uint256 userUsdcBefore = IERC20(USDC).balanceOf(user);

        uint256 sharesToRedeem = userShares / 2;
        uint256 assetsReceived = wPlasmaVault.redeem(sharesToRedeem, user, user);
        vm.stopPrank();

        assertGt(assetsReceived, 0, "redeem should return assets");
        assertEq(wPlasmaVault.balanceOf(user), userShares - sharesToRedeem, "shares should reduce by redeemed");
        assertGt(IERC20(USDC).balanceOf(user), userUsdcBefore, "USDC balance should increase");
    }

    function testTransferredSharesToNonWhitelistedCannotWithdraw() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        address receiver = makeAddr("receiver");

        // grant roles and deposit with whitelisted user
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        uint256 assets = 10_000e6;
        deal(USDC, user, assets);

        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), assets);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        // transfer some shares to non-whitelisted address
        uint256 userShares = wPlasmaVault.balanceOf(user);
        uint256 transferredShares = userShares / 2;
        vm.prank(user);
        wPlasmaVault.transfer(receiver, transferredShares);

        uint256 assetsToWithdraw = wPlasmaVault.convertToAssetsWithFees(transferredShares);

        // receiver attempts to withdraw -> should revert due to missing WHITELISTED role
        vm.startPrank(receiver);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", receiver, whitelisted)
        );
        wPlasmaVault.withdraw(assetsToWithdraw, receiver, receiver);
        vm.stopPrank();
    }

    function testTransferredSharesToNonWhitelistedCannotRedeem() public {
        bytes32 whitelistManager = wPlasmaVault.WHITELIST_MANAGER();
        bytes32 whitelisted = wPlasmaVault.WHITELISTED();

        address receiver = makeAddr("receiver2XXXXX");

        // grant roles and deposit with whitelisted user
        vm.prank(admin);
        wPlasmaVault.grantRole(whitelistManager, manager);
        vm.prank(manager);
        wPlasmaVault.grantRole(whitelisted, user);

        uint256 assets = 10_000e6;
        deal(USDC, user, assets);

        vm.startPrank(user);
        IERC20(USDC).approve(address(wPlasmaVault), assets);
        wPlasmaVault.deposit(assets, user);
        vm.stopPrank();

        // transfer some shares to non-whitelisted address
        uint256 userShares = wPlasmaVault.balanceOf(user);
        uint256 transferredShares = userShares / 2;
        vm.prank(user);
        wPlasmaVault.transfer(receiver, transferredShares);

        // receiver attempts to redeem -> should revert due to missing WHITELISTED role
        vm.startPrank(receiver);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", receiver, whitelisted)
        );
        wPlasmaVault.redeem(transferredShares, receiver, receiver);
        vm.stopPrank();
    }
}
