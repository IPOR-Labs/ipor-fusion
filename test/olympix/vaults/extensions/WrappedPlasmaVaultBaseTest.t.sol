// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";
import {WrappedPlasmaVaultBase} from "contracts/vaults/extensions/WrappedPlasmaVaultBase.sol";
import {WrappedPlasmaVaultBaseHarness} from "test/test_helpers/WrappedPlasmaVaultBaseHarness.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {MockERC4626Vault} from "test/test_helpers/MockERC4626Vault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Target contract: contracts/vaults/extensions/WrappedPlasmaVaultBase.sol
///      (abstract — tested via WrappedPlasmaVaultBaseHarness)
contract WrappedPlasmaVaultBaseTest is OlympixUnitTest("WrappedPlasmaVaultBaseHarness") {
    MockERC20 internal underlyingToken;
    MockERC4626Vault internal plasmaVault;
    WrappedPlasmaVaultBaseHarness internal wrappedVault;

    address internal user;
    address internal managementFeeAccount;
    address internal performanceFeeAccount;

    function setUp() public override {
        user = makeAddr("user");
        managementFeeAccount = makeAddr("managementFeeAccount");
        performanceFeeAccount = makeAddr("performanceFeeAccount");

        underlyingToken = new MockERC20("Mock USD", "mUSD", 6);
        plasmaVault = new MockERC4626Vault(IERC20(address(underlyingToken)));

        wrappedVault = new WrappedPlasmaVaultBaseHarness(
            "Wrapped Base Vault",
            "wBASE",
            address(plasmaVault),
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
        uint256 balanceBefore = underlyingToken.balanceOf(user);

        vm.startPrank(user);
        wrappedVault.deposit(assets, user);
        wrappedVault.withdraw(assets, user, user);
        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(user), balanceBefore, "full withdraw should return all assets");
        assertEq(wrappedVault.balanceOf(user), 0, "no wrapped shares should remain");
    }

    function test_example_constructorZeroPlasmaVaultReverts() public {
        vm.expectRevert(WrappedPlasmaVaultBase.ZeroPlasmaVaultAddress.selector);
        new WrappedPlasmaVaultBaseHarness(
            "Wrapped Base Vault",
            "wBASE",
            address(0),
            managementFeeAccount,
            0,
            performanceFeeAccount,
            0
        );
    }
}
