// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    ExternalStateOperationFuse,
    ExternalStateOperationFuseEnterData,
    ExternalStateOperationFuseExitData
} from "../../../../contracts/fuses/external_state/ExternalStateOperationFuse.sol";
import {IExternalStateExecutor, ExternalStateExecutorAction} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateExecutorStorageLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateExecutorStorageLib.sol";
import {ExternalStateSubstrateLib, ExternalStateSubstrateType} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";

import {MockPlasmaVaultForExternalState} from "./mocks/MockPlasmaVaultForExternalState.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {MockExternalStateTarget} from "./mocks/MockExternalStateTarget.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStateOperationFuseTest
/// @notice 32 unit tests for ExternalStateOperationFuse via delegatecall from MockPlasmaVaultForExternalState.
contract ExternalStateOperationFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    MockPlasmaVaultForExternalState internal vault;
    ExternalStateOperationFuse internal fuse;
    MockPriceOracleMiddleware internal oracle;

    MockERC20ForExternalState internal asset6;
    MockERC20ForExternalState internal asset18;
    MockERC20ForExternalState internal underlying; // same decimals as asset6 for simpler math
    MockExternalStateTarget internal target;

    address internal balanceAccount;
    bytes4 internal constant TARGET_SELECTOR = MockExternalStateTarget.noop.selector;

    function setUp() public {
        vault = new MockPlasmaVaultForExternalState();
        fuse = new ExternalStateOperationFuse(MARKET_ID);
        oracle = new MockPriceOracleMiddleware();
        asset6 = new MockERC20ForExternalState("Asset6", "A6", 6);
        asset18 = new MockERC20ForExternalState("Asset18", "A18", 18);
        underlying = new MockERC20ForExternalState("Underlying", "U", 6);
        target = new MockExternalStateTarget();

        vault.setUnderlying(address(underlying));
        vault.setPriceOracleMiddleware(address(oracle));
        balanceAccount = makeAddr("ba");

        // Default oracle: 1 USD / 1 token for each
        oracle.setPrice(address(asset6), 1e8, 8); // 1 USD in 8-decimal oracle
        oracle.setPrice(address(asset18), 1e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);

        _grantSubstrates();
    }

    // ============================================================
    // 4.1-4.2 Constructor
    // ============================================================

    function test_constructor_setsMarketIdAndVersion() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
        assertEq(fuse.VERSION(), address(fuse));
    }

    function test_constructor_revertsOnZeroMarketId() public {
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateZeroMarketId.selector));
        new ExternalStateOperationFuse(0);
    }

    // ============================================================
    // 4.3-4.6 createExecutor
    // ============================================================

    function test_createExecutor_deploysWhenNone() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address e = _readExecutor();
        assertTrue(e != address(0));
    }

    function test_createExecutor_idempotentWhenAlreadyExists() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address e1 = _readExecutor();
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address e2 = _readExecutor();
        assertEq(e1, e2);
    }

    function test_createExecutor_appliesSubstratesOnNewDeploy() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address e = _readExecutor();
        assertEq(IExternalStateExecutor(e).stalenessMax(), 1 days);
    }

    function test_createExecutor_emitsExecutorCreated() public {
        // Check indexed marketId (topic2) — executor address (topic1) is unknown before deploy
        vm.expectEmit(false, true, false, false, address(vault));
        emit ExternalStateOperationFuse.ExecutorCreated(address(0), MARKET_ID);
        bytes memory ret = _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address executor = abi.decode(ret, (address));
        assertTrue(executor != address(0), "executor deployed");
    }

    // ============================================================
    // 4.7-4.12 enter validation
    // ============================================================

    function test_enter_revertsOnEmptyAssetAndEmptyActions() public {
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(0), amount: 0, balanceAccount: address(0), actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateEmptyAssetAndActions.selector));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenAssetNotGranted() public {
        MockERC20ForExternalState stray = new MockERC20ForExternalState("Stray", "S", 6);
        oracle.setPrice(address(stray), 1e8, 8);
        stray.mint(address(vault), 100e6);

        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(stray), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.ASSET),
                ExternalStateSubstrateLib.encodeAssetSubstrate(address(stray))
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenBalanceAccountNotGranted() public {
        address rogue = makeAddr("rogue");
        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: rogue, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT),
                ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(rogue)
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenTargetSelectorNotGranted() public {
        asset6.mint(address(vault), 100e6);
        bytes4 wrongSel = bytes4(keccak256("notGranted()"));
        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeWithSelector(wrongSel)});
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.TARGET),
                ExternalStateSubstrateLib.encodeTargetSubstrate(address(target), wrongSel)
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenActionDataShorterThan4Bytes() public {
        asset6.mint(address(vault), 100e6);
        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: hex"0102"});
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateActionDataTooShort.selector, uint256(0), uint256(2)));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_doesNotCheckPauseFlag() public {
        // Deploy executor and set paused=true via delegatecall helper
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        _setPaused(true);

        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d))); // must not revert
    }

    // ============================================================
    // 4.13-4.21 enter behavior
    // ============================================================

    function test_enter_transferOnly_noActions() public {
        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));

        address e = _readExecutor();
        assertEq(asset6.balanceOf(e), 100e6);
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 100e6);
    }

    function test_enter_actionsOnly_amountZero() public {
        // Deploy executor first
        _delegate(abi.encodeCall(fuse.createExecutor, ()));

        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeCall(MockExternalStateTarget.noop, ())});
        ExternalStateOperationFuseEnterData memory d =
            ExternalStateOperationFuseEnterData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
        _delegate(abi.encodeCall(fuse.enter, (d)));
        assertEq(target.callsLength(), 1);
    }

    function test_enter_transferAndActions() public {
        asset6.mint(address(vault), 100e6);
        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeCall(MockExternalStateTarget.noop, ())});
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));
        assertEq(target.callsLength(), 1);
        address e = _readExecutor();
        assertEq(asset6.balanceOf(e), 100e6);
    }

    function test_enter_lazyDeploysExecutorOnFirstCall() public {
        asset6.mint(address(vault), 100e6);
        assertEq(_readExecutor(), address(0));
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));
        assertTrue(_readExecutor() != address(0));
    }

    function test_enter_convertsAssetToUnderlyingViaOracle() public {
        asset6.mint(address(vault), 1_000e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 1_000e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));

        address e = _readExecutor();
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        // 1_000e6 of a 1:1 USD asset → 1_000e6 of 6-decimal underlying
        assertEq(total, 1_000e6);
    }

    function test_enter_convertsAssetWithDifferentDecimals() public {
        // 1 asset18 (18d) @ $2 in 8d oracle → 2 USD WAD, underlying=6d @ $1 → 2e6 underlying
        oracle.setPrice(address(asset18), 2e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);
        asset18.mint(address(vault), 1e18);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset18), amount: 1e18, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 2e6);
    }

    function test_enter_revertsOnPriceOracleNotSet() public {
        vault.setPriceOracleMiddleware(address(0));
        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStatePriceOracleNotSet.selector));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsOnZeroPriceFromOracle() public {
        oracle.setPrice(address(asset6), 0, 8);
        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateInvalidPrice.selector, address(asset6)));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_emitsExternalStateOperationFuseEnter() public {
        asset6.mint(address(vault), 100e6);
        ExternalStateOperationFuseEnterData memory d = ExternalStateOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectEmit(true, true, true, true, address(vault));
        emit ExternalStateOperationFuse.ExternalStateOperationFuseEnter(address(fuse), address(asset6), 100e6, balanceAccount, 100e6, 0);
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    // ============================================================
    // 4.22-4.26 exit validation
    // ============================================================

    function test_exit_revertsWhenAssetNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        MockERC20ForExternalState stray = new MockERC20ForExternalState("Stray", "S", 6);
        oracle.setPrice(address(stray), 1e8, 8);
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(stray), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.ASSET),
                ExternalStateSubstrateLib.encodeAssetSubstrate(address(stray))
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenBalanceAccountNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address rogue = makeAddr("rogue");
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: rogue, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.BALANCE_ACCOUNT),
                ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(rogue)
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenTargetSelectorNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        bytes4 wrongSel = bytes4(keccak256("notGranted()"));
        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeWithSelector(wrongSel)});
        ExternalStateOperationFuseExitData memory d =
            ExternalStateOperationFuseExitData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
        vm.expectRevert(
            abi.encodeWithSelector(
                ExternalStateErrors.ExternalStateUnsupportedSubstrate.selector,
                uint8(ExternalStateSubstrateType.TARGET),
                ExternalStateSubstrateLib.encodeTargetSubstrate(address(target), wrongSel)
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenExecutorNotDeployed() public {
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateOperationExecutorNotDeployed.selector));
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenAmountExceedsTrackedBalance() public {
        // enter 100, exit 200 → exceed
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );

        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 200e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStateExitExceedsTrackedBalance.selector, balanceAccount, 200e6, 100e6)
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    // ============================================================
    // 4.27-4.32 exit behavior
    // ============================================================

    function test_exit_actionsThenTransfer_ordering() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );
        address e = _readExecutor();
        // preserve balance on executor

        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeCall(MockExternalStateTarget.noop, ())});
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));

        // action ran
        assertEq(target.callsLength(), 1);
        // balance removed and transferred
        assertEq(asset6.balanceOf(address(vault)), 100e6);
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 0);
    }

    function test_exit_transferOnly() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );

        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        assertEq(asset6.balanceOf(address(vault)), 100e6);
    }

    function test_exit_actionsOnly() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        ExternalStateExecutorAction[] memory acts = new ExternalStateExecutorAction[](1);
        acts[0] = ExternalStateExecutorAction({target: address(target), data: abi.encodeCall(MockExternalStateTarget.noop, ())});
        ExternalStateOperationFuseExitData memory d =
            ExternalStateOperationFuseExitData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
        _delegate(abi.encodeCall(fuse.exit, (d)));
        assertEq(target.callsLength(), 1);
    }

    function test_exit_convertsAssetToUnderlying() public {
        oracle.setPrice(address(asset18), 2e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);
        asset18.mint(address(vault), 1e18);

        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset18),
                        amount: 1e18,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );

        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset18), amount: 1e18, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 0); // fully exited
        assertEq(asset18.balanceOf(address(vault)), 1e18);
    }

    function test_exit_decrementsBalanceAndTransfersToVault() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );

        // exit 40
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 40e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IExternalStateExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 60e6);
        assertEq(asset6.balanceOf(address(vault)), 40e6);
        assertEq(asset6.balanceOf(e), 60e6);
    }

    function test_exit_emitsExternalStateOperationFuseExit() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (ExternalStateOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new ExternalStateExecutorAction[](0)
                    }))
            )
        );
        ExternalStateOperationFuseExitData memory d = ExternalStateOperationFuseExitData({
            asset: address(asset6), amount: 40e6, balanceAccount: balanceAccount, actions: new ExternalStateExecutorAction[](0)
        });
        vm.expectEmit(true, true, true, true, address(vault));
        emit ExternalStateOperationFuse.ExternalStateOperationFuseExit(address(fuse), address(asset6), 40e6, balanceAccount, 40e6, 0);
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _grantSubstrates() internal {
        bytes32[] memory subs = new bytes32[](6);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(asset6));
        subs[1] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(asset18));
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = ExternalStateSubstrateLib.encodeTargetSubstrate(address(target), TARGET_SELECTOR);
        subs[4] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(1 days);
        subs[5] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);
    }

    function _delegate(bytes memory data_) internal returns (bytes memory) {
        return vault.delegateExecute(address(fuse), data_);
    }

    function _readExecutor() internal view returns (address) {
        // Raw ERC-7201 read of executor slot
        bytes32 val = vm.load(address(vault), ExternalStateTestConstants.EXTERNAL_STATE_SLOT);
        return address(uint160(uint256(val)));
    }

    function _setPaused(bool v_) internal {
        ExternalStateSlotHelpers.setPaused(address(vault), v_);
    }
}
