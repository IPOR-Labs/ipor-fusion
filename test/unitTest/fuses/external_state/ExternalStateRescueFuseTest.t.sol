// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {ExternalStateRescueFuse} from "../../../../contracts/fuses/external_state/ExternalStateRescueFuse.sol";
import {ExternalStateExecutor} from "../../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {IExternalStateExecutor} from "../../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateErrors} from "../../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {IporFusionMarkets} from "../../../../contracts/libraries/IporFusionMarkets.sol";
import {ExternalStateSubstrateLib} from "../../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";

import {MockPlasmaVaultForExternalState} from "./mocks/MockPlasmaVaultForExternalState.sol";
import {MockERC20ForExternalState} from "./mocks/MockERC20ForExternalState.sol";
import {ExternalStateTestConstants, ExternalStateSlotHelpers} from "./ExternalStateTestHelpers.sol";

/// @title ExternalStateRescueFuseTest
/// @notice Unit tests for ExternalStateRescueFuse via delegatecall from MockPlasmaVaultForExternalState.
contract ExternalStateRescueFuseTest is Test {
    uint256 internal constant MARKET_ID = IporFusionMarkets.EXTERNAL_STATE;

    MockPlasmaVaultForExternalState internal vault;
    ExternalStateRescueFuse internal fuse;
    ExternalStateExecutor internal executor;
    MockERC20ForExternalState internal asset;
    MockERC20ForExternalState internal airdrop;
    address internal balanceAccount;

    function setUp() public {
        vault = new MockPlasmaVaultForExternalState();
        fuse = new ExternalStateRescueFuse(MARKET_ID);
        asset = new MockERC20ForExternalState("Asset", "A", 6);
        airdrop = new MockERC20ForExternalState("Air", "AIR", 18);
        balanceAccount = makeAddr("ba");

        bytes32[] memory subs = new bytes32[](4);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(address(asset));
        subs[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[2] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(1 days);
        subs[3] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);

        executor = new ExternalStateExecutor(MARKET_ID, address(vault));
        executor.syncSubstrates();
    }

    // ---------- 8.1 ----------
    function test_constructor_setsMarketId() public view {
        assertEq(fuse.MARKET_ID(), MARKET_ID);
    }

    // ---------- 8.2 ----------
    /// @dev Uses `airdrop` (untracked) — `asset` is a registered ASSET substrate and would revert
    ///      with `ExternalStateRescueOfTrackedAssetForbidden` (see test_rescue_revertsForTrackedAsset).
    function test_rescue_transfersAssetFromExecutorToVault() public {
        _storeExecutor();
        airdrop.mint(address(executor), 500e18);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
        assertEq(airdrop.balanceOf(address(vault)), 500e18);
        assertEq(airdrop.balanceOf(address(executor)), 0);
    }

    // ---------- 8.3 ----------
    /// @dev Uses `airdrop` so the `ExternalStateRescueExecutorNotDeployed` revert is reached instead of the
    ///      tracked-asset guard (which depends on the executor existing).
    function test_rescue_revertsWhenExecutorNotDeployed() public {
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateRescueExecutorNotDeployed.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
    }

    /// @notice Rescue with `asset_ == address(0)` must revert with the explicit `ExternalStateZeroAddress`
    ///         error instead of the opaque EVM revert from `IERC20(address(0)).balanceOf(...)`.
    /// @dev The zero-address guard runs BEFORE the executor-deployed check, so this revert is
    ///      observable even on a fresh vault with no executor.
    function test_rescue_revertsOnZeroAddress() public {
        _storeExecutor();
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateZeroAddress.selector));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(0))));
    }

    // ---------- 8.4 ----------
    /// @dev Uses `airdrop` (untracked); rescuing the registered `asset` would now revert.
    function test_rescue_noOpWhenExecutorBalanceZero() public {
        _storeExecutor();
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
        assertEq(airdrop.balanceOf(address(vault)), 0);
    }

    // ---------- 8.5 ----------
    function test_rescue_worksForNonSubstrateAsset() public {
        _storeExecutor();
        airdrop.mint(address(executor), 10 ether);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
        assertEq(airdrop.balanceOf(address(vault)), 10 ether);
    }

    // ---------- 8.6 ----------
    /// @dev Rescue must not mutate tracked balances. Uses `airdrop` (untracked) — the registered
    ///      ASSET substrate is now protected by `ExternalStateRescueOfTrackedAssetForbidden`.
    function test_rescue_doesNotAffectTrackedBalance() public {
        _storeExecutor();
        vm.prank(address(vault));
        IExternalStateExecutor(address(executor)).addBalance(balanceAccount, 12345);
        airdrop.mint(address(executor), 1 ether);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
        assertEq(executor.balances(balanceAccount), 12345);
    }

    // ---------- 8.7 ----------
    function test_rescue_emitsExternalStateAssetRescued() public {
        _storeExecutor();
        vm.expectEmit(true, false, false, true, address(vault));
        emit ExternalStateRescueFuse.ExternalStateAssetRescued(address(airdrop));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(airdrop))));
    }

    // ---------- 8.8 tracked-asset guard ----------
    /// @notice Rescue MUST revert when `asset_` is currently registered as an ASSET substrate
    ///         on the executor. Sweeping a tracked asset out-of-band would desynchronize the
    ///         strategy state between custodian confirms.
    function test_rescue_revertsForTrackedAsset() public {
        _storeExecutor();
        asset.mint(address(executor), 100e6);
        vm.expectRevert(abi.encodeWithSelector(ExternalStateErrors.ExternalStateRescueOfTrackedAssetForbidden.selector, address(asset)));
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(asset))));
        // Funds remain on the executor — rescue did NOT execute.
        assertEq(asset.balanceOf(address(executor)), 100e6);
        assertEq(asset.balanceOf(address(vault)), 0);
    }

    /// @notice After the ASSET substrate is revoked and `syncSubstrates()` is called, the same
    ///         token can be rescued. Confirms the guard reads the current cache, not a stale set.
    function test_rescue_succeedsAfterAssetSubstrateRevoked() public {
        _storeExecutor();
        // Replace substrates with a set that omits `asset`.
        bytes32[] memory subs = new bytes32[](3);
        subs[0] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccount);
        subs[1] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(1 days);
        subs[2] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(1000);
        vault.grantMarketSubstrates(MARKET_ID, subs);
        executor.syncSubstrates();

        asset.mint(address(executor), 250e6);
        vault.delegateExecute(address(fuse), abi.encodeCall(fuse.rescue, (address(asset))));
        assertEq(asset.balanceOf(address(vault)), 250e6);
        assertEq(asset.balanceOf(address(executor)), 0);
    }

    // ============================================================
    // Helpers
    // ============================================================

    function _storeExecutor() internal {
        ExternalStateSlotHelpers.setExecutor(address(vault), address(executor));
    }
}
