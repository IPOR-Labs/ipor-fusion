// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {
    RWAOperationFuse,
    RWAOperationFuseEnterData,
    RWAOperationFuseExitData
} from "../../../../contracts/fuses/rwa/RWAOperationFuse.sol";
import {IRWAExecutor, RWAExecutorAction} from "../../../../contracts/fuses/rwa/IRWAExecutor.sol";
import {RWAExecutorStorageLib} from "../../../../contracts/fuses/rwa/lib/RWAExecutorStorageLib.sol";
import {RWASubstrateLib, RWASubstrateType} from "../../../../contracts/fuses/rwa/lib/RWASubstrateLib.sol";
import {RWAErrors} from "../../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";

import {MockPlasmaVaultForRWA} from "./mocks/MockPlasmaVaultForRWA.sol";
import {MockERC20ForRWA} from "./mocks/MockERC20ForRWA.sol";
import {MockRWATarget} from "./mocks/MockRWATarget.sol";
import {MockPriceOracleMiddleware} from "./mocks/MockPriceOracleMiddleware.sol";
import {RWATestConstants, RWASlotHelpers} from "./RWATestHelpers.sol";

/// @title RWAOperationFuseTest
/// @notice 32 unit tests for RWAOperationFuse via delegatecall from MockPlasmaVaultForRWA.
contract RWAOperationFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.RWA;

    MockPlasmaVaultForRWA internal vault;
    RWAOperationFuse internal fuse;
    MockPriceOracleMiddleware internal oracle;

    MockERC20ForRWA internal asset6;
    MockERC20ForRWA internal asset18;
    MockERC20ForRWA internal underlying; // same decimals as asset6 for simpler math
    MockRWATarget internal target;

    address internal balanceAccount;
    bytes4 internal constant TARGET_SELECTOR = MockRWATarget.noop.selector;

    function setUp() public {
        vault = new MockPlasmaVaultForRWA();
        fuse = new RWAOperationFuse(MARKET_ID);
        oracle = new MockPriceOracleMiddleware();
        asset6 = new MockERC20ForRWA("Asset6", "A6", 6);
        asset18 = new MockERC20ForRWA("Asset18", "A18", 18);
        underlying = new MockERC20ForRWA("Underlying", "U", 6);
        target = new MockRWATarget();

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
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAZeroMarketId.selector));
        new RWAOperationFuse(0);
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

    function test_createExecutor_callsSyncSubstratesOnNewDeploy() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address e = _readExecutor();
        assertEq(IRWAExecutor(e).stalenessMax(), 1 days);
    }

    function test_createExecutor_emitsExecutorCreated() public {
        // Check indexed marketId (topic2) — executor address (topic1) is unknown before deploy
        vm.expectEmit(false, true, false, false, address(vault));
        emit RWAOperationFuse.ExecutorCreated(address(0), MARKET_ID);
        bytes memory ret = _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address executor = abi.decode(ret, (address));
        assertTrue(executor != address(0), "executor deployed");
    }

    // ============================================================
    // 4.7-4.12 enter validation
    // ============================================================

    function test_enter_revertsOnEmptyAssetAndEmptyActions() public {
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(0), amount: 0, balanceAccount: address(0), actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAEmptyAssetAndActions.selector));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenAssetNotGranted() public {
        MockERC20ForRWA stray = new MockERC20ForRWA("Stray", "S", 6);
        oracle.setPrice(address(stray), 1e8, 8);
        stray.mint(address(vault), 100e6);

        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(stray), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.ASSET),
                RWASubstrateLib.encodeAssetSubstrate(address(stray))
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenBalanceAccountNotGranted() public {
        address rogue = makeAddr("rogue");
        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: rogue, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.BALANCE_ACCOUNT),
                RWASubstrateLib.encodeBalanceAccountSubstrate(rogue)
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenTargetSelectorNotGranted() public {
        asset6.mint(address(vault), 100e6);
        bytes4 wrongSel = bytes4(keccak256("notGranted()"));
        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeWithSelector(wrongSel)});
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.TARGET),
                RWASubstrateLib.encodeTargetSubstrate(address(target), wrongSel)
            )
        );
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsWhenActionDataShorterThan4Bytes() public {
        asset6.mint(address(vault), 100e6);
        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: hex"0102"});
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAActionDataTooShort.selector, uint256(0), uint256(2)));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_doesNotCheckPauseFlag() public {
        // Deploy executor and set paused=true via delegatecall helper
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        _setPaused(true);

        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d))); // must not revert
    }

    // ============================================================
    // 4.13-4.21 enter behavior
    // ============================================================

    function test_enter_transferOnly_noActions() public {
        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));

        address e = _readExecutor();
        assertEq(asset6.balanceOf(e), 100e6);
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 100e6);
    }

    function test_enter_actionsOnly_amountZero() public {
        // Deploy executor first
        _delegate(abi.encodeCall(fuse.createExecutor, ()));

        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeCall(MockRWATarget.noop, ())});
        RWAOperationFuseEnterData memory d =
            RWAOperationFuseEnterData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
        _delegate(abi.encodeCall(fuse.enter, (d)));
        assertEq(target.callsLength(), 1);
    }

    function test_enter_transferAndActions() public {
        asset6.mint(address(vault), 100e6);
        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeCall(MockRWATarget.noop, ())});
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
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
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));
        assertTrue(_readExecutor() != address(0));
    }

    function test_enter_convertsAssetToUnderlyingViaOracle() public {
        asset6.mint(address(vault), 1_000e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 1_000e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));

        address e = _readExecutor();
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        // 1_000e6 of a 1:1 USD asset → 1_000e6 of 6-decimal underlying
        assertEq(total, 1_000e6);
    }

    function test_enter_convertsAssetWithDifferentDecimals() public {
        // 1 asset18 (18d) @ $2 in 8d oracle → 2 USD WAD, underlying=6d @ $1 → 2e6 underlying
        oracle.setPrice(address(asset18), 2e8, 8);
        oracle.setPrice(address(underlying), 1e8, 8);
        asset18.mint(address(vault), 1e18);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset18), amount: 1e18, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.enter, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 2e6);
    }

    function test_enter_revertsOnPriceOracleNotSet() public {
        vault.setPriceOracleMiddleware(address(0));
        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAPriceOracleNotSet.selector));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_revertsOnZeroPriceFromOracle() public {
        oracle.setPrice(address(asset6), 0, 8);
        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAInvalidPrice.selector, address(asset6)));
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    function test_enter_emitsRWAOperationFuseEnter() public {
        asset6.mint(address(vault), 100e6);
        RWAOperationFuseEnterData memory d = RWAOperationFuseEnterData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectEmit(true, true, true, true, address(vault));
        emit RWAOperationFuse.RWAOperationFuseEnter(address(fuse), address(asset6), 100e6, balanceAccount, 100e6, 0);
        _delegate(abi.encodeCall(fuse.enter, (d)));
    }

    // ============================================================
    // 4.22-4.26 exit validation
    // ============================================================

    function test_exit_revertsWhenAssetNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        MockERC20ForRWA stray = new MockERC20ForRWA("Stray", "S", 6);
        oracle.setPrice(address(stray), 1e8, 8);
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(stray), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.ASSET),
                RWASubstrateLib.encodeAssetSubstrate(address(stray))
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenBalanceAccountNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        address rogue = makeAddr("rogue");
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: rogue, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.BALANCE_ACCOUNT),
                RWASubstrateLib.encodeBalanceAccountSubstrate(rogue)
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenTargetSelectorNotGranted() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        bytes4 wrongSel = bytes4(keccak256("notGranted()"));
        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeWithSelector(wrongSel)});
        RWAOperationFuseExitData memory d =
            RWAOperationFuseExitData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
        vm.expectRevert(
            abi.encodeWithSelector(
                RWAErrors.RWAUnsupportedSubstrate.selector,
                uint8(RWASubstrateType.TARGET),
                RWASubstrateLib.encodeTargetSubstrate(address(target), wrongSel)
            )
        );
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenExecutorNotDeployed() public {
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWAOperationExecutorNotDeployed.selector));
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    function test_exit_revertsWhenAmountExceedsTrackedBalance() public {
        // enter 100, exit 200 → exceed
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (RWAOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );

        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 200e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAExitExceedsTrackedBalance.selector, balanceAccount, 200e6, 100e6)
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
                (RWAOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );
        address e = _readExecutor();
        // preserve balance on executor

        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeCall(MockRWATarget.noop, ())});
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: acts
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));

        // action ran
        assertEq(target.callsLength(), 1);
        // balance removed and transferred
        assertEq(asset6.balanceOf(address(vault)), 100e6);
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 0);
    }

    function test_exit_transferOnly() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (RWAOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );

        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 100e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        assertEq(asset6.balanceOf(address(vault)), 100e6);
    }

    function test_exit_actionsOnly() public {
        _delegate(abi.encodeCall(fuse.createExecutor, ()));
        RWAExecutorAction[] memory acts = new RWAExecutorAction[](1);
        acts[0] = RWAExecutorAction({target: address(target), data: abi.encodeCall(MockRWATarget.noop, ())});
        RWAOperationFuseExitData memory d =
            RWAOperationFuseExitData({asset: address(0), amount: 0, balanceAccount: address(0), actions: acts});
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
                (RWAOperationFuseEnterData({
                        asset: address(asset18),
                        amount: 1e18,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );

        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset18), amount: 1e18, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 0); // fully exited
        assertEq(asset18.balanceOf(address(vault)), 1e18);
    }

    function test_exit_decrementsBalanceAndTransfersToVault() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (RWAOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );

        // exit 40
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 40e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        _delegate(abi.encodeCall(fuse.exit, (d)));
        address e = _readExecutor();
        (uint256 total,,) = IRWAExecutor(e).getBalanceFuseSnapshot();
        assertEq(total, 60e6);
        assertEq(asset6.balanceOf(address(vault)), 40e6);
        assertEq(asset6.balanceOf(e), 60e6);
    }

    function test_exit_emitsRWAOperationFuseExit() public {
        asset6.mint(address(vault), 100e6);
        _delegate(
            abi.encodeCall(
                fuse.enter,
                (RWAOperationFuseEnterData({
                        asset: address(asset6),
                        amount: 100e6,
                        balanceAccount: balanceAccount,
                        actions: new RWAExecutorAction[](0)
                    }))
            )
        );
        RWAOperationFuseExitData memory d = RWAOperationFuseExitData({
            asset: address(asset6), amount: 40e6, balanceAccount: balanceAccount, actions: new RWAExecutorAction[](0)
        });
        vm.expectEmit(true, true, true, true, address(vault));
        emit RWAOperationFuse.RWAOperationFuseExit(address(fuse), address(asset6), 40e6, balanceAccount, 40e6, 0);
        _delegate(abi.encodeCall(fuse.exit, (d)));
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _grantSubstrates() internal {
        bytes32[] memory subs = new bytes32[](6);
        subs[0] = RWASubstrateLib.encodeAssetSubstrate(address(asset6));
        subs[1] = RWASubstrateLib.encodeAssetSubstrate(address(asset18));
        subs[2] = RWASubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[3] = RWASubstrateLib.encodeTargetSubstrate(address(target), TARGET_SELECTOR);
        subs[4] = RWASubstrateLib.encodeStalenessMaxSubstrate(1 days);
        subs[5] = RWASubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);
    }

    function _delegate(bytes memory data_) internal returns (bytes memory) {
        return vault.delegateExecute(address(fuse), data_);
    }

    function _readExecutor() internal view returns (address) {
        // Raw ERC-7201 read of executor slot
        bytes32 val = vm.load(address(vault), RWATestConstants.RWA_SLOT);
        return address(uint160(uint256(val)));
    }

    function _setPaused(bool v_) internal {
        RWASlotHelpers.setPaused(address(vault), v_);
    }
}
