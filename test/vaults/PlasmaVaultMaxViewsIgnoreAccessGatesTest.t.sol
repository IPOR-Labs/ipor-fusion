// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";

import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IPreHook} from "../../contracts/handlers/pre_hooks/IPreHook.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

import {TestAddresses} from "../test_helpers/TestAddresses.sol";
import {RequestBackingTestBase} from "./request_backing/RequestBackingTestBase.sol";

/// @dev Pre-hook that blocks every selector it is wired on, like a pause or a closed NAV gate
contract MaxViewsBlockingPreHook is IPreHook {
    error MaxViewsBlockingPreHookBlocked(bytes4 selector);

    function run(bytes4 selector_) external pure override {
        revert MaxViewsBlockingPreHookBlocked(selector_);
    }
}

/// @notice IL-9680 (Olympix 2026-11-06 L49), pinning: the ERC-4626 max views of PlasmaVault do not reflect role and
///         pre-hook gates. `maxDeposit` and `maxMint` price only the total supply cap; `maxWithdraw` and `maxRedeem`
///         price the owner's position and, from IL-9679 on, the owner's redemption lock. A receiver or an owner
///         without the role and a pre-hook that blocks the call leave the views positive while the call reverts.
///         Access is decided per caller (`_checkCanCall`), and a view that gets only the receiver or the owner cannot
///         know the caller (a whitelisted caller may deposit for a receiver without a role), so a gated view would
///         give false zeros and false positives. Integrators probe access with
///         `IporFusionAccessManager.canCall(caller, vault, selector)`. Owner decision IL-8639, kept for these gates
///         by Q18 (D-054). The closed vault is the exception (IL-9624 follow-up): it rejects every caller, so all four
///         views return 0 while `isTargetClosed(vault)` is true and come back when the vault is reopened.
/// @dev Harness: RequestBackingTestBase (public vault) turned private the way the initializer does it for
///      `isPublic = false`: deposit, mint and depositWithPermit are mapped to WHITELIST_ROLE.
contract PlasmaVaultMaxViewsIgnoreAccessGatesTest is RequestBackingTestBase {
    address internal constant STRANGER = address(0x57A9);
    uint256 internal constant DEPOSIT = 100_000e6;

    function setUp() public override {
        super.setUp();

        bytes4[] memory entrySelectors = new bytes4[](3);
        entrySelectors[0] = IERC4626.deposit.selector;
        entrySelectors[1] = IERC4626.mint.selector;
        entrySelectors[2] = PlasmaVault.depositWithPermit.selector;
        vm.prank(TestAddresses.ADMIN);
        accessManager.setTargetFunctionRole(address(vault), entrySelectors, Roles.WHITELIST_ROLE);

        vm.prank(ATOMIST);
        accessManager.grantRole(Roles.WHITELIST_ROLE, HONEST, 0);
        vm.label(STRANGER, "stranger");
    }

    // ------------------------------------------------------------------ whitelist on deposit and mint

    function testShouldReportMaxDepositAndMaxMintForReceiverWithoutWhitelistRole() public {
        // given
        _deposit(HONEST, DEPOSIT);
        (bool immediate, uint32 delay) = accessManager.canCall(STRANGER, address(vault), IERC4626.deposit.selector);
        assertFalse(immediate, "stranger cannot deposit");
        assertEq(delay, 0, "no scheduled access either");

        // then - the views price only the supply cap, the same for every receiver
        assertGt(vault.maxDeposit(STRANGER), 0, "maxDeposit positive for a receiver without the role");
        assertGt(vault.maxMint(STRANGER), 0, "maxMint positive for a receiver without the role");
        assertEq(vault.maxDeposit(STRANGER), vault.maxDeposit(HONEST), "maxDeposit does not depend on the receiver");
        assertEq(vault.maxMint(STRANGER), vault.maxMint(HONEST), "maxMint does not depend on the receiver");

        // when / then - the calls revert on the caller's access
        usdc.mint(STRANGER, DEPOSIT);
        vm.startPrank(STRANGER);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        vault.deposit(DEPOSIT, STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        vault.mint(1e8, STRANGER);
        vm.stopPrank();
    }

    /// @dev Why the deposit views cannot be gated by the receiver: access is checked for the caller, so a
    ///      whitelisted caller deposits for a receiver without the role; maxDeposit(receiver) = 0 would be wrong here
    function testShouldLetWhitelistedCallerDepositForReceiverWithoutRole() public {
        // given
        uint256 maxAssets = vault.maxDeposit(STRANGER);
        assertGt(maxAssets, 0, "maxDeposit positive");
        usdc.mint(HONEST, DEPOSIT);

        // when
        vm.startPrank(HONEST);
        usdc.approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, STRANGER);
        vm.stopPrank();

        // then
        assertGt(shares, 0, "shares minted");
        assertEq(vault.balanceOf(STRANGER), shares, "receiver without the role holds the shares");
    }

    // ------------------------------------------------------------------ role on withdraw and redeem

    /// @dev A vault whose exits are restricted to a role (here WHITELIST_ROLE): the owner without the role keeps a
    ///      positive maxWithdraw / maxRedeem after its lock, its own calls revert, and a caller with the role can
    ///      exit for it with an allowance - the exit gate is per caller too
    function testShouldReportMaxWithdrawAndMaxRedeemForOwnerWithoutExitRole() public {
        // given
        bytes4[] memory exitSelectors = new bytes4[](2);
        exitSelectors[0] = IERC4626.withdraw.selector;
        exitSelectors[1] = IERC4626.redeem.selector;
        vm.prank(TestAddresses.ADMIN);
        accessManager.setTargetFunctionRole(address(vault), exitSelectors, Roles.WHITELIST_ROLE);

        usdc.mint(HONEST, DEPOSIT);
        vm.startPrank(HONEST);
        usdc.approve(address(vault), DEPOSIT);
        uint256 shares = vault.deposit(DEPOSIT, STRANGER);
        vm.stopPrank();
        vm.warp(block.timestamp + DELAY);

        (bool immediate, ) = accessManager.canCall(STRANGER, address(vault), IERC4626.redeem.selector);
        assertFalse(immediate, "stranger cannot redeem");

        // then
        assertEq(vault.maxRedeem(STRANGER), shares, "maxRedeem is the balance of an owner without the exit role");
        assertGt(vault.maxWithdraw(STRANGER), 0, "maxWithdraw positive for an owner without the exit role");

        // when / then - the owner's own calls revert
        vm.startPrank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        vault.redeem(shares, STRANGER, STRANGER);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, STRANGER));
        vault.withdraw(1e6, STRANGER, STRANGER);
        vault.approve(HONEST, shares);
        vm.stopPrank();

        // when - a caller with the role redeems the owner's maxRedeem
        uint256 maxShares = vault.maxRedeem(STRANGER);
        vm.prank(HONEST);
        uint256 paid = vault.redeem(maxShares, HONEST, STRANGER);

        // then
        assertGt(paid, 0, "assets paid");
        assertEq(vault.balanceOf(STRANGER), 0, "owner's position redeemed by a caller with the role");
    }

    // ------------------------------------------------------------------ closed vault

    /// @dev IL-9624 follow-up: a closed vault rejects every caller, so the four max views return 0 (ERC-4626: 0 when
    ///      the action is disabled); the role gates below stay unreflected (IL-9680, IL-8639)
    function testShouldReturnZeroMaxViewsWhileVaultIsClosed() public {
        // given
        _deposit(HONEST, DEPOSIT);
        vm.warp(block.timestamp + DELAY);
        uint256 maxDepositBefore = vault.maxDeposit(HONEST);
        uint256 maxMintBefore = vault.maxMint(HONEST);
        uint256 maxWithdrawBefore = vault.maxWithdraw(HONEST);
        uint256 maxRedeemBefore = vault.maxRedeem(HONEST);

        // when
        vm.prank(TestAddresses.GUARDIAN);
        accessManager.updateTargetClosed(address(vault), true);

        // then - the views read 0
        assertTrue(accessManager.isTargetClosed(address(vault)), "vault closed");
        assertGt(maxDepositBefore, 0, "maxDeposit positive before");
        assertGt(maxMintBefore, 0, "maxMint positive before");
        assertGt(maxWithdrawBefore, 0, "maxWithdraw positive before");
        assertGt(maxRedeemBefore, 0, "maxRedeem positive before");
        assertEq(vault.maxDeposit(HONEST), 0, "maxDeposit 0 while closed");
        assertEq(vault.maxMint(HONEST), 0, "maxMint 0 while closed");
        assertEq(vault.maxWithdraw(HONEST), 0, "maxWithdraw 0 while closed");
        assertEq(vault.maxRedeem(HONEST), 0, "maxRedeem 0 while closed");
        (bool immediate, ) = accessManager.canCall(HONEST, address(vault), IERC4626.redeem.selector);
        assertFalse(immediate, "canCall false on a closed vault");

        // when / then - every call reverts
        usdc.mint(HONEST, DEPOSIT);
        vm.startPrank(HONEST);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, HONEST));
        vault.deposit(DEPOSIT, HONEST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, HONEST));
        vault.mint(1e8, HONEST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, HONEST));
        vault.withdraw(maxWithdrawBefore, HONEST, HONEST);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, HONEST));
        vault.redeem(maxRedeemBefore, HONEST, HONEST);
        vm.stopPrank();

        // when / then - reopened, the views come back
        vm.prank(TestAddresses.GUARDIAN);
        accessManager.updateTargetClosed(address(vault), false);
        assertEq(vault.maxDeposit(HONEST), maxDepositBefore, "maxDeposit back after reopening");
        assertEq(vault.maxMint(HONEST), maxMintBefore, "maxMint back after reopening");
        assertEq(vault.maxWithdraw(HONEST), maxWithdrawBefore, "maxWithdraw back after reopening");
        assertEq(vault.maxRedeem(HONEST), maxRedeemBefore, "maxRedeem back after reopening");
    }

    // ------------------------------------------------------------------ pre-hook gate

    function testShouldReportMaxViewsWhilePreHookBlocksTheCall() public {
        // given
        _deposit(HONEST, DEPOSIT);
        vm.warp(block.timestamp + DELAY);
        _wireBlockingPreHook();

        // then
        uint256 maxMint = vault.maxMint(HONEST);
        uint256 maxRedeem = vault.maxRedeem(HONEST);
        assertGt(maxMint, 0, "maxMint positive while the pre-hook blocks mint");
        assertEq(maxRedeem, vault.balanceOf(HONEST), "maxRedeem is the balance while the pre-hook blocks redeem");
        assertGt(vault.maxDeposit(HONEST), 0, "maxDeposit positive while the pre-hook blocks deposit");
        assertGt(vault.maxWithdraw(HONEST), 0, "maxWithdraw positive while the pre-hook blocks withdraw");

        // when / then
        vm.prank(HONEST);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxViewsBlockingPreHook.MaxViewsBlockingPreHookBlocked.selector,
                IERC4626.redeem.selector
            )
        );
        vault.redeem(maxRedeem, HONEST, HONEST);

        usdc.mint(HONEST, DEPOSIT);
        vm.startPrank(HONEST);
        usdc.approve(address(vault), DEPOSIT);
        vm.expectRevert(
            abi.encodeWithSelector(
                MaxViewsBlockingPreHook.MaxViewsBlockingPreHookBlocked.selector,
                IERC4626.mint.selector
            )
        );
        vault.mint(1e8, HONEST);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ the gate the deposit views do price

    function testShouldReturnZeroMaxDepositAndMaxMintAtSupplyCap() public {
        // given
        _deposit(HONEST, DEPOSIT);
        uint256 supply = vault.totalSupply();

        // when
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(vault)).setTotalSupplyCap(supply);

        // then - for every receiver
        assertEq(vault.maxDeposit(HONEST), 0, "maxDeposit 0 at the cap");
        assertEq(vault.maxMint(HONEST), 0, "maxMint 0 at the cap");
        assertEq(vault.maxDeposit(STRANGER), 0, "maxDeposit 0 at the cap, receiver without the role");
        assertEq(vault.maxMint(STRANGER), 0, "maxMint 0 at the cap, receiver without the role");

        usdc.mint(HONEST, 1e6);
        vm.startPrank(HONEST);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Upgradeable.ERC4626ExceededMaxDeposit.selector, HONEST, 1e6, 0));
        vault.deposit(1e6, HONEST);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _wireBlockingPreHook() internal {
        address hook = address(new MaxViewsBlockingPreHook());
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = IERC4626.deposit.selector;
        selectors[1] = IERC4626.mint.selector;
        selectors[2] = IERC4626.withdraw.selector;
        selectors[3] = IERC4626.redeem.selector;
        address[] memory implementations = new address[](4);
        bytes32[][] memory substrates = new bytes32[][](4);
        for (uint256 i; i < 4; ++i) {
            implementations[i] = hook;
            substrates[i] = new bytes32[](0);
        }
        vm.prank(ATOMIST);
        PlasmaVaultGovernance(address(vault)).setPreHookImplementations(selectors, implementations, substrates);
    }
}
