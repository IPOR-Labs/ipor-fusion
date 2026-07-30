// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {WrappedPlasmaVault} from "contracts/vaults/extensions/WrappedPlasmaVault.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626Vault} from "test/test_helpers/MockERC4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Target contract: contracts/vaults/extensions/WrappedPlasmaVault.sol
contract WrappedPlasmaVaultTest is OlympixUnitTest("WrappedPlasmaVault") {
    MockERC20 internal underlyingToken;
    MockERC4626Vault internal plasmaVault;
    WrappedPlasmaVault internal wrappedVault;

    address internal owner;
    address internal user;
    address internal managementFeeAccount;
    address internal performanceFeeAccount;

    function setUp() public override {
        owner = makeAddr("owner");
        user = makeAddr("user");
        managementFeeAccount = makeAddr("managementFeeAccount");
        performanceFeeAccount = makeAddr("performanceFeeAccount");

        underlyingToken = new MockERC20("Mock USD", "mUSD", 6);
        plasmaVault = new MockERC4626Vault(IERC20(address(underlyingToken)));

        wrappedVault = new WrappedPlasmaVault(
            "Wrapped Mock Plasma Vault",
            "wMPV",
            address(plasmaVault),
            owner,
            managementFeeAccount,
            0,
            performanceFeeAccount,
            0
        );

        underlyingToken.mint(user, 1_000_000e6);
        vm.prank(user);
        underlyingToken.approve(address(wrappedVault), type(uint256).max);
    }

    function test_example_deposit() public {
        uint256 assets = 100_000e6;

        vm.prank(user);
        uint256 shares = wrappedVault.deposit(assets, user);

        assertGt(shares, 0, "shares should be minted");
        assertEq(wrappedVault.balanceOf(user), shares, "user should own minted shares");
        assertEq(underlyingToken.balanceOf(address(plasmaVault)), assets, "assets should land in underlying vault");
    }

    function test_example_depositAndWithdraw() public {
        uint256 assets = 50_000e6;

        vm.startPrank(user);
        wrappedVault.deposit(assets, user);
        uint256 balanceBefore = underlyingToken.balanceOf(user);
        wrappedVault.withdraw(25_000e6, user, user);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(user), balanceBefore + 25_000e6, "user should receive withdrawn assets");
    }

    function test_example_constructorZeroOwnerReverts() public {
        vm.expectRevert(WrappedPlasmaVault.ZeroOwnerAddress.selector);
        new WrappedPlasmaVault(
            "Wrapped Mock Plasma Vault",
            "wMPV",
            address(plasmaVault),
            address(0),
            managementFeeAccount,
            0,
            performanceFeeAccount,
            0
        );
    }

    function test_example_unauthorizedConfigureManagementFeeReverts() public {
        vm.prank(user);
        vm.expectRevert();
        wrappedVault.configureManagementFee(user, 100);
    }

    function test_configureManagementFee_onlyOwner() public {
            address newFeeAccount = makeAddr("newFeeAccount");
    
            vm.prank(owner);
            wrappedVault.configureManagementFee(newFeeAccount, 500);
        }
}