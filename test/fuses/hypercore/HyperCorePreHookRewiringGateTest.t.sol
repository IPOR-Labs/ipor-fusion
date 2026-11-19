// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {FusesLib} from "../../../contracts/libraries/FusesLib.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FusionFactoryLogicLib} from "../../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {HyperCoreHookWiringLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreHookWiringLib.sol";
import {HyperCoreCapitalFlowPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowPreHook.sol";
import {HyperCorePendingActionPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCorePendingActionPreHook.sol";
import {PauseFunctionPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/PauseFunctionPreHook.sol";

/// @dev Stands for any flow hook without the HyperCore CapitalFlow marker (EIP-7702 validation, ExternalState pause, ...).
contract RewiringForeignFlowPreHook {
    function run(bytes4) external {}
}

/// @notice IL-9677 (L46): `PlasmaVaultGovernance.setPreHookImplementations` keeps the six share-priced selectors wired to
///         one hook with the HyperCore CapitalFlow marker while the vault has a market-55 balance fuse. Before IL-9677
///         only the exposure-creating action fuses checked the wiring, so a re-wiring after positions were open went
///         through and the unhooked user flow ran without the HyperCore pricing gates.
///         Fixture: the factory vault of `HyperCoreEffectSettlementBase` (market-55 balance fuse, `HyperCoreCapitalFlowPreHook`
///         on the six flows, `HyperCorePendingActionPreHook` on `execute` / `updateMarketsBalances`).
contract HyperCorePreHookRewiringGateTest is HyperCoreEffectSettlementBase {
    /// @dev Artifact of the IL-9628 hook, deployed by path so the file also compiles on the audited base commit.
    string internal constant FULL_REFRESH_HOOK_ARTIFACT =
        "HyperCoreCapitalFlowFullRefreshPreHook.sol:HyperCoreCapitalFlowFullRefreshPreHook";

    address internal _capitalFlowHook;

    function setUp() public override {
        super.setUp();
        _capitalFlowHook = PlasmaVaultGovernance(address(_vault)).getPreHookImplementation(
            PlasmaVault.deposit.selector
        );
        _assertFlowsWiredTo(_capitalFlowHook);
    }

    // ---------------------------------------------------------------------
    // Vault with a market-55 balance fuse: breaking the wiring reverts
    // ---------------------------------------------------------------------

    /// @dev The reported case: unhooking `withdraw` after the vault is live. Reverts and leaves the hook in place.
    function testUnwiringWithdrawRevertsWhileMarket55BalanceFuseIsInstalled() public {
        vm.expectRevert(_notWired(PlasmaVault.withdraw.selector, address(0)));
        _wire(PlasmaVault.withdraw.selector, address(0));

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev Each of the six selectors on its own: removing it, giving it a hook without the marker, giving it the
    ///      PendingAction hook, or giving it a second marker hook while the other five keep the first one all revert.
    function testEveryFlowSelectorCannotBeUnwiredOrReplacedOnItsOwn() public {
        bytes4[6] memory flows = _flowSelectors();
        address foreign = address(new RewiringForeignFlowPreHook());
        address pending = address(new HyperCorePendingActionPreHook());
        address secondCapitalFlow = address(new HyperCoreCapitalFlowPreHook());

        for (uint256 i; i < flows.length; ++i) {
            vm.expectRevert(_notWired(flows[i], address(0)));
            _wire(flows[i], address(0));

            vm.expectRevert(_notWired(flows[i], foreign));
            _wire(flows[i], foreign);

            vm.expectRevert(_notWired(flows[i], pending));
            _wire(flows[i], pending);

            // deposit is read first: a new marker hook there makes depositWithPermit the first mismatch
            if (flows[i] == PlasmaVault.deposit.selector) {
                vm.expectRevert(_notWired(PlasmaVault.depositWithPermit.selector, _capitalFlowHook));
            } else {
                vm.expectRevert(_notWired(flows[i], secondCapitalFlow));
            }
            _wire(flows[i], secondCapitalFlow);
        }

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev Pausing a HyperCore flow with PauseFunctionPreHook (a process rule before IL-9677) is now rejected.
    function testPauseFunctionPreHookOnFlowSelectorReverts() public {
        address pause = address(new PauseFunctionPreHook());

        vm.expectRevert(_notWired(PlasmaVault.redeem.selector, pause));
        _wire(PlasmaVault.redeem.selector, pause);

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, pause));
        _wire(PlasmaVault.deposit.selector, pause);

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev The check runs on the state after the batch: a duplicate selector whose last entry is address(0)
    ///      (PreHooksLib keeps the last value) cannot drop the deposit hook either.
    function testDuplicateSelectorInBatchCannotDropAFlowHook() public {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.deposit.selector;
        address[] memory implementations = new address[](2);
        implementations[0] = _capitalFlowHook;
        implementations[1] = address(0);

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, address(0)));
        _set(selectors, implementations);

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev Moving all six at once to a hook without the marker, or to no hook, is rejected as well.
    function testMovingAllSixFlowsToANonCapitalFlowHookReverts() public {
        address foreign = address(new RewiringForeignFlowPreHook());

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, foreign));
        _wireSix(foreign);

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, address(0)));
        _wireSix(address(0));

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev With an open Core position the guard cannot be shed: removeBalanceFuse(55) reverts above dust, and the
    ///      unwiring keeps reverting.
    function testOpenCorePositionKeepsTheGuard() public {
        _depositToCore(100_000e6);
        _settle(2);
        _refreshAndTotalAssets();

        vm.prank(_fuseManager);
        vm.expectPartialRevert(FusesLib.BalanceFuseNotReadyToRemove.selector);
        PlasmaVaultGovernance(address(_vault)).removeBalanceFuse(MARKET_ID, address(_balanceFuse));

        vm.expectRevert(_notWired(PlasmaVault.withdraw.selector, address(0)));
        _wire(PlasmaVault.withdraw.selector, address(0));

        _assertFlowsWiredTo(_capitalFlowHook);
    }

    // ---------------------------------------------------------------------
    // Vault with a market-55 balance fuse: keeping the wiring passes
    // ---------------------------------------------------------------------

    /// @dev All six moved to a new `HyperCoreCapitalFlowPreHook` in one call (a version upgrade): passes, user flows and
    ///      the action-fuse gate keep working with the new hook.
    function testMovingAllSixFlowsToANewCapitalFlowHookPasses() public {
        address newHook = address(new HyperCoreCapitalFlowPreHook());

        _wireSix(newHook);

        _assertFlowsWiredTo(newHook);
        _userDepositAndRedeem();
        _depositToCore(100_000e6);
        assertTrue(_isPending(), "deposit to Core accepted by the action-fuse gate");
    }

    /// @dev All six moved to `HyperCoreCapitalFlowFullRefreshPreHook` (IL-9628) in one call and back: both marker hooks
    ///      are accepted.
    function testMovingAllSixFlowsToFullRefreshHookAndBackPasses() public {
        address fullRefresh = deployCode(FULL_REFRESH_HOOK_ARTIFACT);

        _wireSix(fullRefresh);
        _assertFlowsWiredTo(fullRefresh);
        _userDepositAndRedeem();

        _wireSix(_capitalFlowHook);
        _assertFlowsWiredTo(_capitalFlowHook);
    }

    /// @dev Selectors outside the six are not checked: execute / updateMarketsBalances can be re-pointed or unhooked,
    ///      and re-registering the same CapitalFlow hook on the six is a no-op that passes.
    function testHookChangesOutsideTheSixFlowsPassWhileWired() public {
        address newPending = address(new HyperCorePendingActionPreHook());
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.execute.selector;
        selectors[1] = PlasmaVault.updateMarketsBalances.selector;
        address[] memory implementations = new address[](2);
        implementations[0] = newPending;
        implementations[1] = newPending;
        _set(selectors, implementations);
        assertEq(_hookOf(PlasmaVault.execute.selector), newPending, "execute re-pointed");

        _wire(PlasmaVault.updateMarketsBalances.selector, address(0));
        assertEq(_hookOf(PlasmaVault.updateMarketsBalances.selector), address(0), "updateMarketsBalances unhooked");

        _wireSix(_capitalFlowHook);
        _assertFlowsWiredTo(_capitalFlowHook);
    }

    // ---------------------------------------------------------------------
    // Vault without a market-55 balance fuse: hooks are free
    // ---------------------------------------------------------------------

    /// @dev Removing the (empty) market-55 balance fuse lifts the guard; adding it again is not gated (fuse and hooks
    ///      may be configured in either order), the action fuses keep capital out of Core while unwired, and the next
    ///      hook change must wire all six in one call.
    function testRemovingMarket55BalanceFuseLiftsTheGuardAndReAddingItRequiresWiringOnTheNextChange() public {
        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).removeBalanceFuse(MARKET_ID, address(_balanceFuse));

        address foreign = address(new RewiringForeignFlowPreHook());
        address pause = address(new PauseFunctionPreHook());
        _wire(PlasmaVault.withdraw.selector, address(0));
        _wire(PlasmaVault.deposit.selector, foreign);
        _wire(PlasmaVault.redeem.selector, pause);
        assertEq(_hookOf(PlasmaVault.withdraw.selector), address(0), "withdraw unhooked without market 55");
        assertEq(_hookOf(PlasmaVault.deposit.selector), foreign, "foreign deposit hook without market 55");
        assertEq(_hookOf(PlasmaVault.redeem.selector), pause, "redeem paused without market 55");

        vm.prank(_fuseManager);
        PlasmaVaultGovernance(address(_vault)).addBalanceFuse(MARKET_ID, address(_balanceFuse));

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, foreign));
        _depositToCore(100_000e6);

        // a change that leaves the six unwired reverts, even when it touches another selector only
        address newPending = address(new HyperCorePendingActionPreHook());
        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, foreign));
        _wire(PlasmaVault.execute.selector, newPending);

        // fixing the deposit hook alone is not enough: withdraw is still unhooked
        vm.expectRevert(_notWired(PlasmaVault.withdraw.selector, address(0)));
        _wire(PlasmaVault.deposit.selector, _capitalFlowHook);

        _wireSix(_capitalFlowHook);
        _assertFlowsWiredTo(_capitalFlowHook);
        _depositToCore(100_000e6);
        assertTrue(_isPending(), "deposit to Core accepted once wired");
    }

    /// @dev A vault that never had market 55 configures its hooks as before IL-9677.
    function testVaultWithoutMarket55ConfiguresHooksFreely() public {
        FusionFactoryLogicLib.FusionInstance memory instance = _fusionFactory.clone(
            "Plain Vault",
            "pvUSDC",
            address(_usdc),
            0,
            _owner,
            0
        );
        PlasmaVault plain = PlasmaVault(instance.plasmaVault);
        vm.prank(_owner);
        IporFusionAccessManager(instance.accessManager).grantRole(Roles.PRE_HOOKS_MANAGER_ROLE, _atomist, 0);

        address foreign = address(new RewiringForeignFlowPreHook());
        address pause = address(new PauseFunctionPreHook());
        _wireOn(plain, PlasmaVault.deposit.selector, foreign);
        _wireOn(plain, PlasmaVault.withdraw.selector, pause);
        _wireOn(plain, PlasmaVault.withdraw.selector, address(0));
        _wireOn(plain, PlasmaVault.redeem.selector, _capitalFlowHook);

        PlasmaVaultGovernance plainGovernance = PlasmaVaultGovernance(address(plain));
        assertEq(
            plainGovernance.getPreHookImplementation(PlasmaVault.deposit.selector),
            foreign,
            "foreign deposit hook"
        );
        assertEq(
            plainGovernance.getPreHookImplementation(PlasmaVault.withdraw.selector),
            address(0),
            "withdraw unhooked"
        );
        assertEq(
            plainGovernance.getPreHookImplementation(PlasmaVault.redeem.selector),
            _capitalFlowHook,
            "partial wiring"
        );
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _userDepositAndRedeem() private {
        _usdc.mint(_user, 1_000e6);
        vm.startPrank(_user);
        _usdc.approve(address(_vault), type(uint256).max);
        uint256 shares = _vault.deposit(1_000e6, _user);
        assertGt(shares, 0, "deposit through the wired hook");
        assertGt(_vault.redeem(shares, _user, _user), 0, "redeem through the wired hook");
        vm.stopPrank();
    }

    function _depositToCore(uint256 amount_) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_depositFuse),
            abi.encodeWithSelector(
                HyperCoreDepositFuse.enter.selector,
                HyperCoreDepositFuseEnterData({tokenIndex: USDC_TOKEN, amount: amount_})
            )
        );
        _vault.execute(actions);
    }

    function _assertFlowsWiredTo(address hook_) private view {
        bytes4[6] memory flows = _flowSelectors();
        for (uint256 i; i < flows.length; ++i) {
            assertEq(_hookOf(flows[i]), hook_, "share-priced selector wiring");
        }
    }

    function _hookOf(bytes4 selector_) private view returns (address) {
        return PlasmaVaultGovernance(address(_vault)).getPreHookImplementation(selector_);
    }

    function _notWired(bytes4 selector_, address implementation_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                HyperCoreHookWiringLib.HyperCorePreHooksNotWired.selector,
                selector_,
                implementation_
            );
    }

    function _wireSix(address hook_) private {
        bytes4[6] memory flows = _flowSelectors();
        bytes4[] memory selectors = new bytes4[](6);
        address[] memory implementations = new address[](6);
        for (uint256 i; i < 6; ++i) {
            selectors[i] = flows[i];
            implementations[i] = hook_;
        }
        _set(selectors, implementations);
    }

    function _wire(bytes4 selector_, address hook_) private {
        _wireOn(_vault, selector_, hook_);
    }

    function _wireOn(PlasmaVault vault_, bytes4 selector_, address hook_) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory implementations = new address[](1);
        implementations[0] = hook_;
        _setOn(vault_, selectors, implementations);
    }

    function _set(bytes4[] memory selectors_, address[] memory implementations_) private {
        _setOn(_vault, selectors_, implementations_);
    }

    function _setOn(PlasmaVault vault_, bytes4[] memory selectors_, address[] memory implementations_) private {
        bytes32[][] memory substrates = new bytes32[][](selectors_.length);
        for (uint256 i; i < selectors_.length; ++i) substrates[i] = new bytes32[](0);
        vm.prank(_atomist);
        PlasmaVaultGovernance(address(vault_)).setPreHookImplementations(selectors_, implementations_, substrates);
    }

    function _flowSelectors() private pure returns (bytes4[6] memory flows) {
        flows[0] = PlasmaVault.deposit.selector;
        flows[1] = PlasmaVault.depositWithPermit.selector;
        flows[2] = PlasmaVault.mint.selector;
        flows[3] = PlasmaVault.withdraw.selector;
        flows[4] = PlasmaVault.redeem.selector;
        flows[5] = PlasmaVault.redeemFromRequest.selector;
    }
}
