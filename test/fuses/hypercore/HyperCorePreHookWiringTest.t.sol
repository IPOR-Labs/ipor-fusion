// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {HyperCoreEffectSettlementBase} from "./HyperCoreEffectSettlementBase.sol";
import {PlasmaVault} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FuseAction} from "../../../contracts/interfaces/IPlasmaVault.sol";
import {Roles} from "../../../contracts/libraries/Roles.sol";
import {
    HyperCoreOrderFuse,
    HyperCoreOrderFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreOrderFuse.sol";
import {
    HyperCoreDepositFuse,
    HyperCoreDepositFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreDepositFuse.sol";
import {
    HyperCoreMarginFuse,
    HyperCoreMarginFuseEnterData
} from "../../../contracts/fuses/hypercore/HyperCoreMarginFuse.sol";
import {HyperCoreLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreLib.sol";
import {HyperCoreHookWiringLib} from "../../../contracts/fuses/hypercore/lib/HyperCoreHookWiringLib.sol";
import {CoreSimulatorLib} from "./simulation/CoreSimulatorLib.sol";
import {HyperCoreCapitalFlowPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCoreCapitalFlowPreHook.sol";
import {HyperCorePendingActionPreHook} from "../../../contracts/handlers/pre_hooks/pre_hooks/HyperCorePendingActionPreHook.sol";

/// @dev Stands for any non-HyperCore flow hook (EIP-7702 validation, ExternalState pause, ...): runs, refreshes nothing.
contract ForeignFlowPreHook {
    function run(bytes4) external {}
}

/// @notice IL-8529: both HyperCore pre-hooks must refuse to run under a selector they are not meant for.
///         Mis-wiring is reproduced on the factory-vault fixture by re-pointing single selectors after the
///         correct M4 installation done in setUp. The action fuses additionally refuse to create Core exposure
///         while the six share-priced selectors are not all wired to a HyperCoreCapitalFlowPreHook.
contract HyperCorePreHookWiringTest is HyperCoreEffectSettlementBase {
    address internal _alpha = makeAddr("ALPHA");
    address internal _correctFlowHook;
    HyperCoreCapitalFlowPreHook internal _capitalFlow;
    HyperCorePendingActionPreHook internal _pendingAction;

    function setUp() public override {
        super.setUp();
        _capitalFlow = new HyperCoreCapitalFlowPreHook();
        _pendingAction = new HyperCorePendingActionPreHook();
        _correctFlowHook = PlasmaVaultGovernance(address(_vault)).getPreHookImplementation(
            PlasmaVault.deposit.selector
        );
        vm.prank(_atomist);
        _accessManager.grantRole(Roles.ALPHA_ROLE, _alpha, 0);
    }

    // a. CapitalFlow on updateMarketsBalances: explicit error instead of FailedInnerCall recursion.
    function testCapitalFlowOnUpdateMarketsBalancesReverts() public {
        _wire(PlasmaVault.updateMarketsBalances.selector, address(_capitalFlow));
        uint256[] memory marketIds = _marketIdsOf(MARKET_ID);
        vm.prank(_atomist);
        vm.expectRevert(_wrongSelector(PlasmaVault.updateMarketsBalances.selector));
        _vault.updateMarketsBalances(marketIds);
    }

    // b. CapitalFlow on execute: would revert execute (CapitalFlow hook) even when nothing is pending.
    function testCapitalFlowOnExecuteReverts() public {
        _wire(PlasmaVault.execute.selector, address(_capitalFlow));
        vm.prank(_alpha);
        vm.expectRevert(_wrongSelector(PlasmaVault.execute.selector));
        _vault.execute(new FuseAction[](0));
    }

    // c. PendingAction on deposit / redeem reverts even when nothing is pending.
    function testPendingActionOnDepositRevertsWhenNotPending() public {
        _wire(PlasmaVault.deposit.selector, address(_pendingAction));
        assertFalse(_isPending(), "nothing pending");
        _usdc.mint(_user, 1e6);
        vm.prank(_user);
        _usdc.approve(address(_vault), type(uint256).max);
        vm.prank(_user);
        vm.expectRevert(_wrongSelector(PlasmaVault.deposit.selector));
        _vault.deposit(1e6, _user);
    }

    function testPendingActionOnRedeemRevertsWhenNotPending() public {
        _wire(PlasmaVault.redeem.selector, address(_pendingAction));
        assertFalse(_isPending(), "nothing pending");
        vm.prank(_user);
        vm.expectRevert(_wrongSelector(PlasmaVault.redeem.selector));
        _vault.redeem(1e8, _user, _user);
    }

    // d. direct run() coverage for every denied selector of each hook (the check precedes any storage read).
    function testPendingActionRunRevertsOnEveryShareFlowSelector() public {
        bytes4[6] memory flows = _flowSelectors();
        for (uint256 i; i < flows.length; ++i) {
            vm.expectRevert(_wrongSelector(flows[i]));
            _pendingAction.run(flows[i]);
        }
    }

    function testCapitalFlowRunRevertsOnExecuteAndUpdateMarketsBalances() public {
        vm.expectRevert(_wrongSelector(PlasmaVault.execute.selector));
        _capitalFlow.run(PlasmaVault.execute.selector);
        vm.expectRevert(_wrongSelector(PlasmaVault.updateMarketsBalances.selector));
        _capitalFlow.run(PlasmaVault.updateMarketsBalances.selector);
    }

    function testPendingActionRunAcceptsExecuteAndUpdateMarketsBalances() public {
        _pendingAction.run(PlasmaVault.execute.selector);
        _pendingAction.run(PlasmaVault.updateMarketsBalances.selector);
    }

    // e. correct M4 wiring (installed in setUp) works.
    function testCorrectWiringFlowsWork() public {
        _usdc.mint(_user, 1_000e6);
        vm.prank(_user);
        _usdc.approve(address(_vault), type(uint256).max);
        vm.prank(_user);
        uint256 shares = _vault.deposit(1_000e6, _user);
        assertGt(shares, 0, "deposit");
        vm.prank(_user);
        assertGt(_vault.redeem(shares, _user, _user), 0, "redeem");

        vm.prank(_alpha);
        _vault.execute(new FuseAction[](0));

        vm.prank(_atomist);
        _vault.updateMarketsBalances(_marketIdsOf(MARKET_ID));
    }

    // f. IL-8529 wiring gate in the exposure-creating fuses.
    // i. no hooks at all on the six flows (the Keyring-demo state): no capital reaches Core.
    function testDepositToCoreWithoutAnyFlowHooksReverts() public {
        _wireFlows(address(0), address(0));
        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, address(0)));
        _depositToCore(100_000e6);
    }

    // ii. the old 4-of-6 list (depositWithPermit and redeemFromRequest unhooked) is rejected.
    function testDepositToCoreWithFourOfSixFlowHooksReverts() public {
        _wireFlows(_correctFlowHook, address(0));
        vm.expectRevert(_notWired(PlasmaVault.depositWithPermit.selector, address(0)));
        _depositToCore(100_000e6);
    }

    // iii. a foreign hook (no CapitalFlow marker) on all six flows is rejected.
    function testDepositToCoreWithForeignFlowHookReverts() public {
        address foreign = address(new ForeignFlowPreHook());
        _wireFlows(foreign, foreign);
        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, foreign));
        _depositToCore(100_000e6);
    }

    // iii-b. IL-8938: each of the six share-priced selectors is required on its own. The gate reverts for the
    //        selector that is unwired (address(0)) and for the one that carries a foreign hook, one at a time.
    function testEveryShareFlowSelectorIsRequiredByTheWiringGate() public {
        bytes4[6] memory flows = _flowSelectors();
        address foreign = address(new ForeignFlowPreHook());
        for (uint256 i; i < flows.length; ++i) {
            uint256 snapshot = vm.snapshotState();
            _wire(flows[i], address(0));
            vm.expectRevert(_notWired(flows[i], address(0)));
            _depositToCore(100_000e6);
            vm.revertToState(snapshot);

            snapshot = vm.snapshotState();
            _wire(flows[i], foreign);
            vm.expectRevert(_notWired(flows[i], foreign));
            _depositToCore(100_000e6);
            vm.revertToState(snapshot);
        }
    }

    // iv. correct wiring: deposit to Core, margin and an opening order all go through.
    function testCorrectWiringFullCoreCycleWorks() public {
        assertGt(_openLong(), 0, "deposit, margin and an opening order go through");
    }

    // v. mis-wired vault with an open position: opening orders are blocked, de-risking is not.
    function testMisWiredVaultWithOpenPositionBlocksOpeningOrderButAllowsUnwind() public {
        _openLong();
        _wireFlows(address(0), address(0));

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, address(0)));
        _executeOrder(true, 50e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);

        // reduce-only close is not gated
        _executeOrder(false, 40e8, 1000e8, true, HyperCoreLib.TIF_IOC, CLOID_3);

        // margin moves are not gated either
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 1_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
    }

    // v-b. IL-8938: opening orders require the last selector of the gate list (redeemFromRequest) as well.
    function testOpeningOrderRequiresEveryShareFlowSelectorWired() public {
        _openLong();
        _wire(PlasmaVault.redeemFromRequest.selector, address(0));

        vm.expectRevert(_notWired(PlasmaVault.redeemFromRequest.selector, address(0)));
        _executeOrder(true, 50e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
    }

    // vi. KNOWN LIMITATION: a re-wiring after exposure exists is not detected by the user flows. Here deposit loses
    //     its hook through a duplicate selector in one call (PreHooksLib keeps the last value). The unhooked deposit
    //     runs no HyperCore code and is NOT blocked; only the next opening order notices. Process controls
    //     (timelock on PRE_HOOKS_MANAGER_ROLE, PreHookImplementationChanged monitoring) cover this case.
    function testLaterPartialRewiringIsNotBlockedOnUserFlowsButBlocksNextOpeningOrder() public {
        _openLong();
        _dropDepositHookViaDuplicate();

        _usdc.mint(_user, 1_000e6);
        vm.startPrank(_user);
        _usdc.approve(address(_vault), type(uint256).max);
        assertGt(_vault.deposit(1_000e6, _user), 0, "unhooked deposit is not blocked (known limitation)");
        vm.stopPrank();

        vm.expectRevert(_notWired(PlasmaVault.deposit.selector, address(0)));
        _executeOrder(true, 50e8, 10e8, false, HyperCoreLib.TIF_IOC, CLOID_2);
    }

    function _openLong() private returns (uint256 navFresh) {
        _depositToCore(100_000e6);
        _settle(2);
        _refreshAndTotalAssets();
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_marginFuse),
            abi.encodeWithSelector(
                HyperCoreMarginFuse.enter.selector,
                HyperCoreMarginFuseEnterData({usd6: 50_000e6, toPerp: true})
            )
        );
        _vault.execute(actions);
        _settle(2);
        _refreshAndTotalAssets();
        CoreSimulatorLib.forcePerpLeverage(address(_vault), HYPE_PERP, 1);
        CoreSimulatorLib.setMarkPx(HYPE_PERP, 400_000);
        CoreSimulatorLib.setOraclePx(HYPE_PERP, 400_000);
        _executeOrder(true, 45e8, 1000e8, false, HyperCoreLib.TIF_IOC, CLOID_1);
        _settle(10);
        navFresh = _refreshAndTotalAssets();
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

    function _executeOrder(
        bool isBuy_,
        uint64 limitPx_,
        uint64 sz_,
        bool reduceOnly_,
        uint8 tif_,
        uint128 cloid_
    ) private {
        FuseAction[] memory actions = new FuseAction[](1);
        actions[0] = FuseAction(
            address(_orderFuse),
            abi.encodeWithSelector(
                HyperCoreOrderFuse.enter.selector,
                HyperCoreOrderFuseEnterData({
                    asset: HYPE_PERP,
                    isBuy: isBuy_,
                    limitPx: limitPx_,
                    sz: sz_,
                    reduceOnly: reduceOnly_,
                    tif: tif_,
                    cloid: cloid_
                })
            )
        );
        _vault.execute(actions);
    }

    function _dropDepositHookViaDuplicate() private {
        bytes4[] memory selectors = new bytes4[](2);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.deposit.selector;
        address[] memory implementations = new address[](2);
        implementations[0] = _correctFlowHook;
        implementations[1] = address(0);
        _set(selectors, implementations);
    }

    function _notWired(bytes4 selector_, address implementation_) private pure returns (bytes memory) {
        return
            abi.encodeWithSelector(
                HyperCoreHookWiringLib.HyperCorePreHooksNotWired.selector,
                selector_,
                implementation_
            );
    }

    /// @dev flows4_ -> deposit/mint/withdraw/redeem, flows2_ -> depositWithPermit/redeemFromRequest
    function _wireFlows(address flows4_, address flows2_) private {
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PlasmaVault.deposit.selector;
        selectors[1] = PlasmaVault.mint.selector;
        selectors[2] = PlasmaVault.withdraw.selector;
        selectors[3] = PlasmaVault.redeem.selector;
        selectors[4] = PlasmaVault.depositWithPermit.selector;
        selectors[5] = PlasmaVault.redeemFromRequest.selector;
        address[] memory implementations = new address[](6);
        for (uint256 i; i < 4; ++i) implementations[i] = flows4_;
        implementations[4] = flows2_;
        implementations[5] = flows2_;
        _set(selectors, implementations);
    }

    function _set(bytes4[] memory selectors_, address[] memory implementations_) private {
        bytes32[][] memory substrates = new bytes32[][](selectors_.length);
        for (uint256 i; i < selectors_.length; ++i) substrates[i] = new bytes32[](0);
        vm.prank(_atomist);
        PlasmaVaultGovernance(address(_vault)).setPreHookImplementations(selectors_, implementations_, substrates);
    }

    function _flowSelectors() private pure returns (bytes4[6] memory flows) {
        flows[0] = PlasmaVault.deposit.selector;
        flows[1] = PlasmaVault.depositWithPermit.selector;
        flows[2] = PlasmaVault.mint.selector;
        flows[3] = PlasmaVault.withdraw.selector;
        flows[4] = PlasmaVault.redeem.selector;
        flows[5] = PlasmaVault.redeemFromRequest.selector;
    }

    function _wrongSelector(bytes4 selector_) private pure returns (bytes memory) {
        return abi.encodeWithSelector(HyperCoreCapitalFlowPreHook.HyperCorePreHookWrongSelector.selector, selector_);
    }

    function _wire(bytes4 selector_, address hook_) private {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector_;
        address[] memory implementations = new address[](1);
        implementations[0] = hook_;
        bytes32[][] memory substrates = new bytes32[][](1);
        substrates[0] = new bytes32[](0);
        vm.prank(_atomist);
        PlasmaVaultGovernance(address(_vault)).setPreHookImplementations(selectors, implementations, substrates);
    }
}
