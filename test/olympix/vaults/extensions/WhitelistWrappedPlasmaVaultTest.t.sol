// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {WhitelistWrappedPlasmaVault} from "contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol";
import {WhitelistAccessControl} from "contracts/vaults/extensions/WhitelistAccessControl.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626Vault} from "test/test_helpers/MockERC4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Target contract: contracts/vaults/extensions/WhitelistWrappedPlasmaVault.sol
contract WhitelistWrappedPlasmaVaultTest is OlympixUnitTest("WhitelistWrappedPlasmaVault") {
    MockERC20 internal underlyingToken;
    MockERC4626Vault internal plasmaVault;
    WhitelistWrappedPlasmaVault internal wrappedVault;

    address internal admin;
    address internal user;
    address internal managementFeeAccount;
    address internal performanceFeeAccount;

    function setUp() public override {
        admin = makeAddr("admin");
        user = makeAddr("user");
        managementFeeAccount = makeAddr("managementFeeAccount");
        performanceFeeAccount = makeAddr("performanceFeeAccount");

        underlyingToken = new MockERC20("Mock USD", "mUSD", 6);
        plasmaVault = new MockERC4626Vault(IERC20(address(underlyingToken)));

        wrappedVault = new WhitelistWrappedPlasmaVault(
            "Whitelist Wrapped Vault",
            "wlWPV",
            address(plasmaVault),
            admin,
            managementFeeAccount,
            0,
            performanceFeeAccount,
            0
        );

        // role chain: DEFAULT_ADMIN_ROLE (admin) -> WHITELIST_MANAGER -> WHITELISTED
        vm.startPrank(admin);
        wrappedVault.grantRole(wrappedVault.WHITELIST_MANAGER(), admin);
        wrappedVault.grantRole(wrappedVault.WHITELISTED(), user);
        vm.stopPrank();

        underlyingToken.mint(user, 1_000_000e6);
        vm.prank(user);
        underlyingToken.approve(address(wrappedVault), type(uint256).max);
    }

    function test_example_whitelistedDepositSucceeds() public {
        uint256 assets = 100_000e6;

        vm.prank(user);
        uint256 shares = wrappedVault.deposit(assets, user);

        assertGt(shares, 0, "shares should be minted");
        assertEq(underlyingToken.balanceOf(address(plasmaVault)), assets, "assets should land in underlying vault");
    }

    function test_example_nonWhitelistedDepositReverts() public {
        address stranger = makeAddr("stranger");
        underlyingToken.mint(stranger, 1_000e6);
        vm.startPrank(stranger);
        underlyingToken.approve(address(wrappedVault), type(uint256).max);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                stranger,
                wrappedVault.WHITELISTED()
            )
        );
        wrappedVault.deposit(1_000e6, stranger);
        vm.stopPrank();
    }

    function test_example_constructorZeroAdminReverts() public {
        vm.expectRevert(WhitelistAccessControl.ZeroAdminAddress.selector);
        new WhitelistWrappedPlasmaVault(
            "Whitelist Wrapped Vault",
            "wlWPV",
            address(plasmaVault),
            address(0),
            managementFeeAccount,
            0,
            performanceFeeAccount,
            0
        );
    }

    function test_configureManagementFee_onlyAdminRoleAllowed_branchTrue() public {
            // configureManagementFee is onlyRole(DEFAULT_ADMIN_ROLE), admin has that role from constructor
            vm.prank(admin);
            wrappedVault.configureManagementFee(managementFeeAccount, 100);
            // No revert expected: reaching this line confirms the `if (true)` true-branch was executed
        }

    function test_configurePerformanceFee_AdminCanCall() public {
            // configure some non-zero performance fee as admin to hit the true branch
            vm.prank(admin);
            wrappedVault.configurePerformanceFee(performanceFeeAccount, 100);
        }

    function test_mint_whitelistedUser_hitsMintWrapperBranch() public {
            uint256 sharesToMint = 1_000e6;
    
            vm.prank(user);
            uint256 assets = wrappedVault.mint(sharesToMint, user);
    
            assertGt(assets, 0, "assets should be required to mint shares");
        }

    function test_withdraw_WhitelistWrappedVaultWithdrawCallsBaseWithdraw() public {
            // Arrange: ensure user has shares by depositing first
            uint256 assets = 10_000e6;
            vm.prank(user);
            uint256 shares = wrappedVault.deposit(assets, user);
    
            // Act: user withdraws via the wrapped vault
            vm.prank(user);
            uint256 burnedShares = wrappedVault.withdraw(assets / 2, user, user);
    
            // Assert: branch in WhitelistWrappedPlasmaVault.withdraw (if (true)) is executed
            // and underlying base logic burns some shares
            assertGt(burnedShares, 0, "Some shares should be burned on withdraw");
            assertLt(wrappedVault.balanceOf(user), shares, "User share balance should decrease after withdraw");
        }

    function test_redeem_WhitelistedUserHitsTrueBranch() public {
            uint256 depositAssets = 100_000e6;
    
            // user deposits first to get shares
            vm.prank(user);
            uint256 mintedShares = wrappedVault.deposit(depositAssets, user);
    
            // redeem those shares; user is WHITELISTED so call should succeed and enter the body (true branch)
            vm.prank(user);
            uint256 redeemedAssets = wrappedVault.redeem(mintedShares, user, user);
    
            assertEq(redeemedAssets, depositAssets, "redeemed assets should equal initial deposit in this mock setup");
        }
}