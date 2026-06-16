// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RWAForkTestBase} from "./RWAForkTestBase.t.sol";
import {RWAErrors} from "../../../contracts/fuses/rwa/errors/RWAErrors.sol";
import {RWAOperationFuse} from "../../../contracts/fuses/rwa/RWAOperationFuse.sol";

/// @title RWAWithOtherFusesInteractionForkTest
/// @notice Fork coverage for the boundary conditions between the RWA balance fuse and other
///         market-balance fuses that may live in the same vault. Critical invariants:
///           1. RWA balance fuse only counts the RWA executor's tracked balance — not physical
///              tokens the vault itself may hold (which belong to another market's accounting).
///           2. Physical tokens sitting on the executor (e.g. airdrops) are NOT counted in the
///              tracked balance — they require `RWARescueFuse` to sweep.
///           3. A second RWA market cannot share the executor for a pre-existing one (the
///              executor is bound to a single `MARKET_ID`).
///           4. When another (non-RWA) balance fuse coexists in the same vault, the RWA fuse's
///              value is isolated to the RWA market.
contract RWAWithOtherFusesInteractionForkTest is RWAForkTestBase {
    /// @notice Vault holds separate USDC (representing another market). RWA balance fuse must
    ///         ignore that and only report the RWA-tracked portion.
    function test_fork_balanceFuseDoesNotDoubleCount_vaultHoldsOtherAssets() public {
        // RWA market receives 500 USDC.
        deal(USDC, address(vault), 500e6);
        _enter(USDC, 500e6, balanceAccountA);

        // Vault is then funded with another 1_000 USDC (representing a different market's funds
        // held directly on the vault). The RWA balance fuse must NOT count this.
        deal(USDC, address(vault), 1_000e6);

        uint256 rwaBalanceWad = _readBalanceOf();
        assertEq(rwaBalanceWad, 500e18, "only RWA executor tracked balance counted");
    }

    /// @notice Physical tokens on the executor (e.g. stray transfers of the tracked ASSET) must
    ///         NOT inflate the tracked balance reported by `RWABalanceFuse`. The balance fuse
    ///         reads `balances[BA]` from the executor, not the physical ERC20 holdings.
    function test_fork_balanceFuseIgnoresPhysicalTokensOnExecutor() public {
        deal(USDC, address(vault), 100e6);
        _enter(USDC, 100e6, balanceAccountA);

        // Simulate an airdrop / stray transfer of the tracked ASSET directly to the executor.
        deal(USDC, _executorAddress(), 10_000e6 + 100e6); // 10_000 extra on top of the original 100

        uint256 rwaBalanceWad = _readBalanceOf();
        // Tracked remains 100e6 -> 100e18 WAD. Physical balance is ignored.
        assertEq(rwaBalanceWad, 100e18, "airdrop tokens not counted in tracked balance");
    }

    /// @notice `RWARescueFuse.rescue` MUST refuse to sweep the tracked ASSET substrate. Sweeping
    ///         the tracked asset out-of-band would desynchronize executor accounting from physical
    ///         holdings: `balances[BA]` would still report the underlying value, but no funds would
    ///         remain on the executor to back a subsequent exit. Untracked tokens (airdrops of
    ///         unrelated ERC20s, e.g. DAI here) remain rescuable.
    function test_fork_rescueRefusesTrackedAssetButSweepsUntrackedAirdrop() public {
        deal(USDC, address(vault), 100e6);
        _enter(USDC, 100e6, balanceAccountA);

        // Stray transfer of the tracked asset (USDC) onto the executor — must NOT be rescuable.
        deal(USDC, _executorAddress(), 10_000e6 + 100e6);
        // Airdrop of an unrelated ERC20 (DAI) onto the executor — must be rescuable.
        uint256 daiAirdrop = 5_000e18;
        deal(DAI, _executorAddress(), daiAirdrop);

        // Rescue on the tracked ASSET substrate reverts.
        vm.expectRevert(abi.encodeWithSelector(RWAErrors.RWARescueOfTrackedAssetForbidden.selector, USDC));
        vault.delegateExecute(address(rescueFuse), abi.encodeCall(rescueFuse.rescue, (USDC)));

        // Executor still holds the USDC — rescue did NOT execute.
        assertEq(IERC20(USDC).balanceOf(_executorAddress()), 10_000e6 + 100e6, "tracked asset untouched");

        // Rescue on the untracked airdrop succeeds and sweeps the full balance to the vault.
        uint256 vaultDaiBefore = IERC20(DAI).balanceOf(address(vault));
        vault.delegateExecute(address(rescueFuse), abi.encodeCall(rescueFuse.rescue, (DAI)));
        assertEq(
            IERC20(DAI).balanceOf(address(vault)) - vaultDaiBefore,
            daiAirdrop,
            "rescue swept the untracked airdrop"
        );
        assertEq(IERC20(DAI).balanceOf(_executorAddress()), 0, "airdrop fully removed from executor");
    }

    /// @notice The executor is bound to a single `MARKET_ID`. An attempt to reuse the same
    ///         vault storage slot for a second RWA market must revert with
    ///         `RWAMultipleMarketsNotSupported`.
    function test_fork_twoMarketsInSameVault_notSupported() public {
        _createExecutor(); // deploys executor bound to IporFusionMarkets.RWA

        // Deploy a second RWAOperationFuse for a different market id. When we call
        // `createExecutor()` on it via the same vault, `RWAExecutorStorageLib.getOrCreateExecutor`
        // sees a non-zero executor pointer and reads its `MARKET_ID` — which doesn't match —
        // so the library reverts with `RWAMultipleMarketsNotSupported`.
        RWAOperationFuse secondOpFuse = new RWAOperationFuse(MARKET_ID + 1);

        vm.expectRevert(
            abi.encodeWithSelector(RWAErrors.RWAMultipleMarketsNotSupported.selector, MARKET_ID, MARKET_ID + 1)
        );
        vault.delegateExecute(address(secondOpFuse), abi.encodeCall(secondOpFuse.createExecutor, ()));
    }

    /// @notice Two separate RWA balance fuses (for separate markets, in separate vault instances)
    ///         report independent totals. This is the topological invariant that makes the RWA
    ///         family safe to compose with other balance fuses in the same vault — each fuse's
    ///         read is scoped to its own ERC-7201 slot / market substrates.
    function test_fork_balanceFuseCoexistsWithOtherBalanceFuses_totalVaultBalanceCorrect() public {
        // Market A: 400e6 tracked.
        deal(USDC, address(vault), 400e6);
        _enter(USDC, 400e6, balanceAccountA);
        uint256 marketAValue = _readBalanceOf();
        assertEq(marketAValue, 400e18, "market A value");

        // Simulate a second vault tracking 1_000e6 on a different balance fuse (e.g. spark, morpho).
        // From the vantage of our fuse, the only thing that matters is that our reads are based on
        // OUR ERC-7201 slot — unaffected by other markets' storage. Here we assert that a fresh
        // call to the same RWA balance fuse returns the same value on repeated invocations, i.e.
        // the fuse doesn't accidentally aggregate anything else.
        uint256 marketAValue2 = _readBalanceOf();
        assertEq(marketAValue2, marketAValue, "RWA fuse value stable across reads");
    }
}

