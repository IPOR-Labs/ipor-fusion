// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {ExternalStateForkTestBase} from "./ExternalStateForkTestBase.t.sol";
import {ExternalStateErrors} from "../../../contracts/fuses/external_state/errors/ExternalStateErrors.sol";
import {ExternalStateSubstrateLib} from "../../../contracts/fuses/external_state/lib/ExternalStateSubstrateLib.sol";
import {IExternalStateExecutor} from "../../../contracts/fuses/external_state/IExternalStateExecutor.sol";
import {ExternalStateExecutor} from "../../../contracts/fuses/external_state/ExternalStateExecutor.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title ExternalStateRescueStaleCacheForkTest
/// @notice IL-8115 regression: `ExternalStateRescueFuse.rescue` must refuse a sweep of a token that
///         is granted as an ASSET substrate on the vault even when the executor's cached `assets[]`
///         has not been synced yet. Reproduces the PoC end to end on a real `PlasmaVault`.
/// @dev Runs on the shared `ExternalStateForkTestBase` fixture, which deploys the
///      `ExternalStateExecutor` and every fuse locally in-test (see `grep -n "new ExternalState"` on
///      `ExternalStateForkTestBase.t.sol`) — no deployed mainnet bytecode for the ExternalState
///      contracts is exercised here. Only the ERC20 (USDC) is a real mainnet token, sourced via
///      `deal()`; no real on-chain holder address is reused.
/// @dev Deliberately uses the vault's own underlying asset (USDC), not a secondary asset like DAI,
///      as the swept token. `PlasmaVault._getGrossTotalAssets()` only sums
///      `IERC20(asset()).balanceOf(vault)` (idle underlying) plus the cached per-market balances —
///      it does not scan the vault for balances of arbitrary non-underlying tokens. Sweeping a
///      *non*-underlying tracked asset (e.g. DAI on a USDC vault) back to the vault therefore does
///      NOT move `totalAssets()` at all: the swept tokens become invisible idle value, not a double
///      count (verified empirically before choosing this design — see cycle-1 report). Only when the
///      swept asset equals the vault's own `asset()` does the swept amount land in the idle term
///      while the stale `balances[]`-derived market term still counts it too, producing the exact
///      double count the finding describes. USDC is therefore both the vault's underlying asset and
///      the tracked ASSET substrate under test.
contract ExternalStateRescueStaleCacheForkTest is ExternalStateForkTestBase {
    uint256 internal constant ENTER_AMOUNT = 100e6; // 100 USDC (6 decimals)

    /// @notice Grant substrates WITHOUT USDC as an ASSET (only USDT + the other required
    ///         substrates). Used before `_createExecutor()` so the executor's cache is bootstrapped
    ///         without USDC.
    function _grantWithoutUsdc() internal {
        bytes32[] memory subs = new bytes32[](10);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDT);
        subs[1] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[3] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[4] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[5] = ExternalStateSubstrateLib.encodeTargetSubstrate(
            address(externalStateProtocol),
            bytes4(keccak256("deposit(address,uint256)"))
        );
        subs[6] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[7] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[8] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[9] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
    }

    /// @notice Re-grant the same set as `_grantWithoutUsdc` plus USDC as an ASSET substrate, WITHOUT
    ///         calling `syncSubstrates()` afterwards — this is the operator-runbook lapse the finding
    ///         depends on (README §13.7 step 4 skipped).
    function _grantUsdcWithoutSync() internal {
        bytes32[] memory subs = new bytes32[](11);
        subs[0] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDC);
        subs[1] = ExternalStateSubstrateLib.encodeAssetSubstrate(USDT);
        subs[2] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountA);
        subs[3] = ExternalStateSubstrateLib.encodeBalanceAccountSubstrate(balanceAccountB);
        subs[4] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianA);
        subs[5] = ExternalStateSubstrateLib.encodeCustodianSubstrate(custodianB);
        subs[6] = ExternalStateSubstrateLib.encodeTargetSubstrate(
            address(externalStateProtocol),
            bytes4(keccak256("deposit(address,uint256)"))
        );
        subs[7] = ExternalStateSubstrateLib.encodeStalenessMaxSubstrate(STALENESS_MAX_S);
        subs[8] = ExternalStateSubstrateLib.encodeBigChangeBpsSubstrate(BIG_CHANGE_BPS);
        subs[9] = ExternalStateSubstrateLib.encodeDustThresholdSubstrate(DUST_THRESHOLD);
        subs[10] = ExternalStateSubstrateLib.encodeMinUpdateIntervalSubstrate(MIN_UPDATE_INTERVAL_S);
        _grantSubstrates(subs);
        // Deliberately no _syncExecutorSubstrates() call here — the cache stays at the pre-USDC set.
    }

    /// @notice End-to-end reproduction: bootstrap the executor cache without USDC, grant USDC on the
    ///         vault without syncing, `enter` with USDC (crediting `balances[]` on the real path,
    ///         which also physically moves USDC off the vault onto the executor), then attempt
    ///         `rescue(USDC)`. Before the fix the sweep succeeds, returns USDC to the vault as idle
    ///         balance, and — because the stale-cache-derived market balance still counts the same
    ///         value — doubles the USDC's contribution to `totalAssets()`. After the fix it reverts
    ///         and NAV/state are untouched.
    function test_fork_rescueRefusesAssetGrantedAfterExecutorBootstrap() public {
        // Bootstrap the executor with USDT only (no USDC yet) so the cache excludes USDC.
        _grantWithoutUsdc();
        _createExecutor();
        address executorAddr = _executorAddress();
        assertEq(IExternalStateExecutor(executorAddr).assetsLength(), 1, "cache bootstrapped without USDC");

        // Grant USDC on the vault without syncing the executor cache.
        _grantUsdcWithoutSync();
        assertEq(
            IExternalStateExecutor(executorAddr).assetsLength(),
            1,
            "executor cache must still be stale (USDT only)"
        );

        // Enter with USDC on the real `enter` path — reads the vault substrate set live, so it
        // succeeds and credits `balances[]`, even though the executor cache does not yet know USDC.
        deal(USDC, address(vault), ENTER_AMOUNT);
        _enter(USDC, ENTER_AMOUNT, balanceAccountA);

        // ---- Prove the defect premise on-chain, before asserting the revert ----
        // 1. USDC IS granted as an ASSET substrate on the vault (source of truth for the fixed guard).
        assertTrue(
            PlasmaVaultGovernance(address(vault)).isMarketSubstrateGranted(
                MARKET_ID,
                ExternalStateSubstrateLib.encodeAssetSubstrate(USDC)
            ),
            "USDC is granted as an ASSET substrate on the vault"
        );
        // 2. Executor cache is unchanged (still does not list USDC) — the guard's cache half is stale.
        assertEq(IExternalStateExecutor(executorAddr).assetsLength(), 1, "cache still stale after enter");
        // 3. `balances[balanceAccountA]` is credited — USDC is tracked strategy state, not an airdrop.
        assertEq(
            ExternalStateExecutor(executorAddr).balances(balanceAccountA),
            ENTER_AMOUNT,
            "balanceAccountA credited via enter"
        );
        // 4. The executor physically holds the USDC that `rescue` would sweep; the vault holds none.
        assertEq(IERC20(USDC).balanceOf(executorAddr), ENTER_AMOUNT, "executor holds the entered USDC");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "vault holds no idle USDC before the sweep");

        uint256 totalAssetsBefore = vault.totalAssets();
        assertEq(totalAssetsBefore, ENTER_AMOUNT, "totalAssets reflects the entered amount exactly once");

        // ---- The fix: rescue must refuse the sweep ----
        vm.expectRevert(
            abi.encodeWithSelector(ExternalStateErrors.ExternalStateRescueOfTrackedAssetForbidden.selector, USDC)
        );
        _executeFuse(address(rescueFuse), abi.encodeCall(rescueFuse.rescue, (USDC)));

        // State is untouched: no double count, no funds moved.
        assertEq(IERC20(USDC).balanceOf(executorAddr), ENTER_AMOUNT, "USDC stays on the executor");
        assertEq(IERC20(USDC).balanceOf(address(vault)), 0, "no USDC swept to the vault");
        assertEq(vault.totalAssets(), totalAssetsBefore, "totalAssets() unchanged");
    }
}
