// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultLib} from "../../libraries/PlasmaVaultLib.sol";
import {IporMath} from "../../libraries/math/IporMath.sol";
import {IPriceOracleMiddleware} from "../../price_oracle/IPriceOracleMiddleware.sol";

import {IExternalStateExecutor, ExternalStateExecutorAction} from "./IExternalStateExecutor.sol";
import {ExternalStateErrors} from "./errors/ExternalStateErrors.sol";
import {ExternalStateExecutorStorageLib} from "./lib/ExternalStateExecutorStorageLib.sol";
import {ExternalStateBigChangeLib} from "./lib/ExternalStateBigChangeLib.sol";
import {ExternalStateSubstrateLib} from "./lib/ExternalStateSubstrateLib.sol";

/// @notice Enter data for the ExternalState operation fuse.
/// @param asset ERC20 asset being transferred from vault to executor (may be zero-address if `amount == 0`).
/// @param amount Asset token amount to transfer (in asset decimals). Zero means "actions-only".
/// @param balanceAccount Balance account bucket receiving the deposit accounting.
/// @param actions External calls to perform from the executor context (e.g. approve+deposit).
struct ExternalStateOperationFuseEnterData {
    address asset;
    uint256 amount;
    address balanceAccount;
    ExternalStateExecutorAction[] actions;
}

/// @notice Exit data for the ExternalState operation fuse (same shape as enter but semantics invert: actions run first,
///         then tracked balance is decremented and the asset is pulled back to the vault).
struct ExternalStateOperationFuseExitData {
    address asset;
    uint256 amount;
    address balanceAccount;
    ExternalStateExecutorAction[] actions;
}

/// @title ExternalStateOperationFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) that orchestrates ExternalState enter/exit flows:
///         validates substrates, lazily deploys the executor, transfers tokens to/from the executor,
///         and forwards batched external actions.
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`
///      and delegatecall-safe library calls are allowed.
/// @author IPOR Labs
contract ExternalStateOperationFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Deployment address captured at construction; recorded in events for audit trails.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted the first time `createExecutor` causes an executor to be deployed
    ///         (also fires on subsequent idempotent calls for transparency).
    event ExecutorCreated(address executor, uint256 marketId);

    /// @notice Emitted after a successful `enter` call.
    event ExternalStateOperationFuseEnter(
        address version,
        address asset,
        uint256 amount,
        address balanceAccount,
        uint256 valueInUnderlying,
        uint256 actionsCount
    );

    /// @notice Emitted after a successful `exit` call.
    event ExternalStateOperationFuseExit(
        address version,
        address asset,
        uint256 amount,
        address balanceAccount,
        uint256 valueInUnderlying,
        uint256 actionsCount
    );

    /// @notice Emitted after a successful `sweepSurplus` call.
    event ExternalStateOperationFuseSweepSurplus(address version, address asset, uint256 amount);

    /// @param marketId_ Market identifier this fuse will serve (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert ExternalStateErrors.ExternalStateZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Explicitly deploy the executor (idempotent). Useful to separate deployment cost
    ///         from the first enter call.
    /// @return executor Address of the deployed executor.
    function createExecutor() external returns (address executor) {
        executor = ExternalStateExecutorStorageLib.getOrCreateExecutor(MARKET_ID);
        emit ExecutorCreated(executor, MARKET_ID);
    }

    /// @notice Enter the ExternalState market: optionally transfer `amount` of `asset` to the executor, convert it to
    ///         underlying via the price oracle and credit the balance account; then (optionally) run actions.
    /// @dev Before any transfer or accounting, a pending custodian confirm is settled (big-change check against the
    ///      pre-flow baseline), so ALPHA's own flow can neither trip the pause nor mask a custodian change (IL-8775).
    ///      A pause set here does not block this call.
    /// @param data_ Enter parameters.
    function enter(ExternalStateOperationFuseEnterData calldata data_) external {
        (address executor, uint256 actionsCount) = _resolveExecutorAndValidate(
            data_.amount,
            data_.asset,
            data_.balanceAccount,
            data_.actions,
            true
        );

        // Settle a pending custodian confirm BEFORE ALPHA's flow moves `balances[]` (IL-8775).
        ExternalStateBigChangeLib.processCustodianUpdate(executor);

        uint256 valueInUnderlying;
        if (data_.amount > 0) {
            IERC20(data_.asset).safeTransfer(executor, data_.amount);
            valueInUnderlying = _convertAmountToUnderlying(data_.asset, data_.amount);
            IExternalStateExecutor(executor).addBalance(
                data_.balanceAccount,
                valueInUnderlying,
                data_.asset,
                data_.amount
            );
        }

        if (actionsCount > 0) {
            IExternalStateExecutor(executor).execute(data_.actions);
        }

        emit ExternalStateOperationFuseEnter(
            VERSION,
            data_.asset,
            data_.amount,
            data_.balanceAccount,
            valueInUnderlying,
            actionsCount
        );
    }

    /// @notice Exit the ExternalState market: optionally run actions first (to free funds on the executor), then
    ///         decrement the balance account and pull `amount` of `asset` back to the vault.
    /// @dev Like `enter`, settles a pending custodian confirm before actions and `removeBalance` run (IL-8775).
    /// @param data_ Exit parameters.
    function exit(ExternalStateOperationFuseExitData calldata data_) external {
        (address executor, uint256 actionsCount) = _resolveExecutorAndValidate(
            data_.amount,
            data_.asset,
            data_.balanceAccount,
            data_.actions,
            false
        );

        // Settle a pending custodian confirm BEFORE ALPHA's flow moves `balances[]` (IL-8775).
        ExternalStateBigChangeLib.processCustodianUpdate(executor);

        if (actionsCount > 0) {
            IExternalStateExecutor(executor).execute(data_.actions);
        }

        uint256 valueInUnderlying;
        if (data_.amount > 0) {
            valueInUnderlying = _convertAmountToUnderlying(data_.asset, data_.amount);
            IExternalStateExecutor(executor).removeBalance(
                data_.balanceAccount,
                valueInUnderlying,
                data_.asset,
                data_.amount
            );
        }

        emit ExternalStateOperationFuseExit(
            VERSION,
            data_.asset,
            data_.amount,
            data_.balanceAccount,
            valueInUnderlying,
            actionsCount
        );
    }

    /// @notice Move tokens that were donated to the executor (sent by third parties, not through `enter`) to the vault.
    /// @dev The executor transfers `balanceOf(executor) - min(unforwardedCredit[asset], balanceOf(executor))`,
    ///      i.e. the tokens not covered by the credit counter (donations and anything that arrived outside a vault call). `balances[]` and the credit
    ///      counter stay unchanged, so credited tokens that still sit on the executor are never touched. The
    ///      swept tokens become vault assets and enter NAV immediately only when `asset_` is the
    ///      vault underlying (any other asset is valued through its own balance fuse/market as usual).
    ///      `asset_` must be a granted ASSET substrate (same rule as `enter`/`exit`); the executor must already exist (no lazy deployment).
    ///      Zero surplus is a no-op.
    ///      Trust model: surplus is "everything not covered by `unforwardedCredit`", so tokens that return to the
    ///      executor outside a vault call (custody or protocol payouts sent straight to it) look like donations.
    ///      Such tokens are in NAV only while the last confirmed custodian report counts them.
    ///      Still counted (a custody or protocol payout sent straight to the executor before the next report): book them
    ///      with `exit`, while `unforwardedCredit(asset) == 0` (forward or exit credited tokens first: `removeBalance`
    ///      debits the credit by the exited amount, whatever its origin).
    ///      No longer counted (a donation, or a confirmed report that already excludes them): `sweepSurplus`, never `exit`
    ///      (an exit would remove the value a second time).
    ///      Custodians do not propose while `balanceOf(executor) > unforwardedCredit(asset)` for a cached asset unless they
    ///      know whether their report counts those tokens (the dust check does not block them). Monitoring: alert when
    ///      `balanceOf(executor) > unforwardedCredit(asset)`.
    ///      A counterparty that pulls tokens outside `execute` leaves the credit stale (above the token balance):
    ///      up to that amount, tokens that later reach the executor count in the dust check (a donation can block
    ///      custodians again) and `sweepSurplus` does not move them. Each `exit` or `execute` outflow consumes only
    ///      its own amount of the credit, so the block can return until outflows totalling the stale credit have run.
    ///      Does not settle a pending custodian confirm: it leaves `balances[]` unchanged, so it cannot move the
    ///      total that the big-change check compares (IL-8775).
    /// @param asset_ ASSET substrate to sweep.
    function sweepSurplus(address asset_) external {
        address executor = ExternalStateExecutorStorageLib.getExecutor();
        if (executor == address(0)) revert ExternalStateErrors.ExternalStateOperationExecutorNotDeployed();

        ExternalStateSubstrateLib.validateAssetGranted(MARKET_ID, asset_);

        uint256 amount = IExternalStateExecutor(executor).sweepSurplus(asset_);

        emit ExternalStateOperationFuseSweepSurplus(VERSION, asset_, amount);
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    /// @dev Shared enter/exit guards + executor lookup + substrate validation.
    ///      Reverts with `ExternalStateEmptyAssetAndActions` when the caller provides nothing to do,
    ///      and (on exit only) with `ExternalStateOperationExecutorNotDeployed` when the executor has not
    ///      yet been lazily deployed.
    /// @param amount_ Asset amount (in asset decimals). Zero means "actions-only".
    /// @param asset_ Asset being transferred (ignored when `amount_ == 0`).
    /// @param balanceAccount_ Balance account bucket (ignored when `amount_ == 0`).
    /// @param actions_ Batched external calls forwarded to the executor.
    /// @param createIfMissing_ On `true` (enter path) the executor is lazily deployed; on `false`
    ///        (exit path) the call reverts if no executor exists yet.
    /// @return executor Resolved executor address.
    /// @return actionsCount Cached `actions_.length` to avoid re-computing it in the caller.
    function _resolveExecutorAndValidate(
        uint256 amount_,
        address asset_,
        address balanceAccount_,
        ExternalStateExecutorAction[] calldata actions_,
        bool createIfMissing_
    ) internal returns (address executor, uint256 actionsCount) {
        actionsCount = actions_.length;
        if (amount_ == 0 && actionsCount == 0) {
            revert ExternalStateErrors.ExternalStateEmptyAssetAndActions();
        }

        if (createIfMissing_) {
            executor = ExternalStateExecutorStorageLib.getOrCreateExecutor(MARKET_ID);
        } else {
            executor = ExternalStateExecutorStorageLib.getExecutor();
            if (executor == address(0)) revert ExternalStateErrors.ExternalStateOperationExecutorNotDeployed();
        }

        _validateSubstratesAndActions(amount_, asset_, balanceAccount_, actions_, actionsCount);
    }

    /// @dev Validate asset and balance account substrates (if amount > 0) and action target+selector grants.
    function _validateSubstratesAndActions(
        uint256 amount_,
        address asset_,
        address balanceAccount_,
        ExternalStateExecutorAction[] calldata actions_,
        uint256 actionsCount_
    ) internal view {
        if (amount_ > 0) {
            ExternalStateSubstrateLib.validateAssetGranted(MARKET_ID, asset_);
            ExternalStateSubstrateLib.validateBalanceAccountGranted(MARKET_ID, balanceAccount_);
        }
        _validateActionTargets(actions_, actionsCount_);
    }

    /// @dev Iterate actions and validate TARGET+selector substrate grant for every action.
    ///      Reverts with `ExternalStateUnsupportedSubstrate` on the first mismatch.
    ///      Actions with `data.length < 4` are rejected via `ExternalStateActionDataTooShort` because
    ///      a 4-byte selector cannot be derived.
    ///
    ///      **Security note (M-3):** no on-chain check prevents an atomist from granting an ASSET
    ///      address as a TARGET (e.g. `(USDC, transfer.selector)`). If both grants coexist, Alpha
    ///      can drain the executor's token balance via
    ///      `actions = [{ target: asset, data: transfer(attacker, bal) }]` without decrementing
    ///      `balances[]`. Substrate-grant reviews MUST confirm `target ∉ assets` for every TARGET
    ///      grant. See `contracts/fuses/external_state/README.md` ("Trust assumptions → TARGET substrates
    ///      must not overlap with ASSET substrates") for the operator playbook.
    function _validateActionTargets(ExternalStateExecutorAction[] calldata actions_, uint256 count_) internal view {
        for (uint256 i; i < count_; ++i) {
            bytes calldata d = actions_[i].data;
            if (d.length < 4) revert ExternalStateErrors.ExternalStateActionDataTooShort(i, d.length);
            bytes4 selector = bytes4(d[:4]);
            ExternalStateSubstrateLib.validateTargetSelectorGranted(MARKET_ID, actions_[i].target, selector);
        }
    }

    /// @dev Convert an asset amount into vault underlying units via the plasma vault's price oracle middleware.
    ///      Uses the same USD→underlying chain as `AsyncExecutor._convertUsdToUnderlyingAmount`.
    ///
    ///      **Security note (M-4):** the price is consumed at execution time and feeds directly into
    ///      `balances[balanceAccount]` on enter (and decrements on exit). A flash-loan-manipulable
    ///      oracle (e.g. raw Uniswap V2 spot) lets Alpha inflate `valueInUnderlying` during enter,
    ///      unwind the loan in the same block, and exit later at the real price — pocketing the
    ///      delta. Only TWAP / Chainlink push-or-pull / Pyth-with-staleness oracles are acceptable
    ///      as the `PriceOracleMiddleware` source for this market. Governance MUST verify the
    ///      oracle binding before enabling user deposits — this is enforced **off-chain only**.
    ///      See `contracts/fuses/external_state/README.md` ("Oracle requirements").
    function _convertAmountToUnderlying(
        address asset_,
        uint256 amount_
    ) internal view returns (uint256 underlyingAmount) {
        address priceOracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracle == address(0)) revert ExternalStateErrors.ExternalStatePriceOracleNotSet();

        (uint256 assetPrice, uint256 assetPriceDecimals) = IPriceOracleMiddleware(priceOracle).getAssetPrice(asset_);
        if (assetPrice == 0) revert ExternalStateErrors.ExternalStateInvalidPrice(asset_);

        address underlying = IERC4626(address(this)).asset();
        (uint256 underlyingPrice, uint256 underlyingPriceDecimals) = IPriceOracleMiddleware(priceOracle).getAssetPrice(
            underlying
        );
        if (underlyingPrice == 0) revert ExternalStateErrors.ExternalStateInvalidPrice(underlying);

        uint256 assetDecimals = IERC20Metadata(asset_).decimals();
        uint256 underlyingDecimals = IERC20Metadata(underlying).decimals();

        // USD (in 1e18 WAD): amount * assetPrice scaled to 18 = WAD(USD)
        uint256 usdWad = IporMath.convertToWad(amount_ * assetPrice, assetDecimals + assetPriceDecimals);

        // underlying price normalized to WAD
        uint256 underlyingPriceWad = IporMath.convertToWad(underlyingPrice, underlyingPriceDecimals);

        underlyingAmount = (usdWad * (10 ** underlyingDecimals)) / underlyingPriceWad;
    }
}
