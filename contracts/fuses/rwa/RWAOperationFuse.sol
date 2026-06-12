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

import {IRWAExecutor, RWAExecutorAction} from "./IRWAExecutor.sol";
import {RWAErrors} from "./errors/RWAErrors.sol";
import {RWAExecutorStorageLib} from "./lib/RWAExecutorStorageLib.sol";
import {RWASubstrateLib} from "./lib/RWASubstrateLib.sol";

/// @notice Enter data for the RWA operation fuse.
/// @param asset ERC20 asset being transferred from vault to executor (may be zero-address if `amount == 0`).
/// @param amount Asset token amount to transfer (in asset decimals). Zero means "actions-only".
/// @param balanceAccount Balance account bucket receiving the deposit accounting.
/// @param actions External calls to perform from the executor context (e.g. approve+deposit).
struct RWAOperationFuseEnterData {
    address asset;
    uint256 amount;
    address balanceAccount;
    RWAExecutorAction[] actions;
}

/// @notice Exit data for the RWA operation fuse (same shape as enter but semantics invert: actions run first,
///         then tracked balance is decremented and the asset is pulled back to the vault).
struct RWAOperationFuseExitData {
    address asset;
    uint256 amount;
    address balanceAccount;
    RWAExecutorAction[] actions;
}

/// @title RWAOperationFuse
/// @notice Stateless fuse (delegatecall from PlasmaVault) that orchestrates RWA enter/exit flows:
///         validates substrates, lazily deploys the executor, transfers tokens to/from the executor,
///         and forwards batched external actions.
/// @dev Runs in the PlasmaVault storage context. MUST NOT declare storage variables; only `immutable`
///      and delegatecall-safe library calls are allowed.
/// @author IPOR Labs
contract RWAOperationFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Deployment address captured at construction; recorded in events for audit trails.
    address public immutable VERSION;

    /// @notice Market identifier bound to this fuse instance.
    uint256 public immutable override MARKET_ID;

    /// @notice Emitted the first time `createExecutor` causes an executor to be deployed
    ///         (also fires on subsequent idempotent calls for transparency).
    event ExecutorCreated(address executor, uint256 marketId);

    /// @notice Emitted after a successful `enter` call.
    event RWAOperationFuseEnter(
        address version,
        address asset,
        uint256 amount,
        address balanceAccount,
        uint256 valueInUnderlying,
        uint256 actionsCount
    );

    /// @notice Emitted after a successful `exit` call.
    event RWAOperationFuseExit(
        address version,
        address asset,
        uint256 amount,
        address balanceAccount,
        uint256 valueInUnderlying,
        uint256 actionsCount
    );

    /// @param marketId_ Market identifier this fuse will serve (must be non-zero).
    constructor(uint256 marketId_) {
        if (marketId_ == 0) revert RWAErrors.RWAZeroMarketId();
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Explicitly deploy the executor (idempotent). Useful to separate deployment cost
    ///         from the first enter call.
    /// @return executor Address of the deployed executor.
    function createExecutor() external returns (address executor) {
        executor = RWAExecutorStorageLib.getOrCreateExecutor(MARKET_ID);
        emit ExecutorCreated(executor, MARKET_ID);
    }

    /// @notice Enter the RWA market: optionally transfer `amount` of `asset` to the executor, convert it to
    ///         underlying via the price oracle and credit the balance account; then (optionally) run actions.
    /// @param data_ Enter parameters.
    function enter(RWAOperationFuseEnterData calldata data_) external {
        (address executor, uint256 actionsCount) =
            _resolveExecutorAndValidate(data_.amount, data_.asset, data_.balanceAccount, data_.actions, true);

        uint256 valueInUnderlying;
        if (data_.amount > 0) {
            IERC20(data_.asset).safeTransfer(executor, data_.amount);
            valueInUnderlying = _convertAmountToUnderlying(data_.asset, data_.amount);
            IRWAExecutor(executor).addBalance(data_.balanceAccount, valueInUnderlying);
        }

        if (actionsCount > 0) {
            IRWAExecutor(executor).execute(data_.actions);
        }

        emit RWAOperationFuseEnter(
            VERSION, data_.asset, data_.amount, data_.balanceAccount, valueInUnderlying, actionsCount
        );
    }

    /// @notice Exit the RWA market: optionally run actions first (to free funds on the executor), then
    ///         decrement the balance account and pull `amount` of `asset` back to the vault.
    /// @param data_ Exit parameters.
    function exit(RWAOperationFuseExitData calldata data_) external {
        (address executor, uint256 actionsCount) =
            _resolveExecutorAndValidate(data_.amount, data_.asset, data_.balanceAccount, data_.actions, false);

        if (actionsCount > 0) {
            IRWAExecutor(executor).execute(data_.actions);
        }

        uint256 valueInUnderlying;
        if (data_.amount > 0) {
            valueInUnderlying = _convertAmountToUnderlying(data_.asset, data_.amount);
            IRWAExecutor(executor).removeBalance(data_.balanceAccount, valueInUnderlying, data_.asset, data_.amount);
        }

        emit RWAOperationFuseExit(
            VERSION, data_.asset, data_.amount, data_.balanceAccount, valueInUnderlying, actionsCount
        );
    }

    // ============================================================
    // Internal helpers
    // ============================================================

    /// @dev Shared enter/exit guards + executor lookup + substrate validation.
    ///      Reverts with `RWAEmptyAssetAndActions` when the caller provides nothing to do,
    ///      and (on exit only) with `RWAOperationExecutorNotDeployed` when the executor has not
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
        RWAExecutorAction[] calldata actions_,
        bool createIfMissing_
    ) internal returns (address executor, uint256 actionsCount) {
        actionsCount = actions_.length;
        if (amount_ == 0 && actionsCount == 0) {
            revert RWAErrors.RWAEmptyAssetAndActions();
        }

        if (createIfMissing_) {
            executor = RWAExecutorStorageLib.getOrCreateExecutor(MARKET_ID);
        } else {
            executor = RWAExecutorStorageLib.getExecutor();
            if (executor == address(0)) revert RWAErrors.RWAOperationExecutorNotDeployed();
        }

        _validateSubstratesAndActions(amount_, asset_, balanceAccount_, actions_, actionsCount);
    }

    /// @dev Validate asset and balance account substrates (if amount > 0) and action target+selector grants.
    function _validateSubstratesAndActions(
        uint256 amount_,
        address asset_,
        address balanceAccount_,
        RWAExecutorAction[] calldata actions_,
        uint256 actionsCount_
    ) internal view {
        if (amount_ > 0) {
            RWASubstrateLib.validateAssetGranted(MARKET_ID, asset_);
            RWASubstrateLib.validateBalanceAccountGranted(MARKET_ID, balanceAccount_);
        }
        _validateActionTargets(actions_, actionsCount_);
    }

    /// @dev Iterate actions and validate TARGET+selector substrate grant for every action.
    ///      Reverts with `RWAUnsupportedSubstrate` on the first mismatch.
    ///      Actions with `data.length < 4` are rejected via `RWAActionDataTooShort` because
    ///      a 4-byte selector cannot be derived.
    ///
    ///      **Security note (M-3):** no on-chain check prevents an atomist from granting an ASSET
    ///      address as a TARGET (e.g. `(USDC, transfer.selector)`). If both grants coexist, Alpha
    ///      can drain the executor's token balance via
    ///      `actions = [{ target: asset, data: transfer(attacker, bal) }]` without decrementing
    ///      `balances[]`. Substrate-grant reviews MUST confirm `target ∉ assets` for every TARGET
    ///      grant. See `contracts/fuses/rwa/README.md` ("Trust assumptions → TARGET substrates
    ///      must not overlap with ASSET substrates") for the operator playbook.
    function _validateActionTargets(RWAExecutorAction[] calldata actions_, uint256 count_) internal view {
        for (uint256 i; i < count_; ++i) {
            bytes calldata d = actions_[i].data;
            if (d.length < 4) revert RWAErrors.RWAActionDataTooShort(i, d.length);
            bytes4 selector = bytes4(d[:4]);
            RWASubstrateLib.validateTargetSelectorGranted(MARKET_ID, actions_[i].target, selector);
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
    ///      See `contracts/fuses/rwa/README.md` ("Oracle requirements").
    function _convertAmountToUnderlying(address asset_, uint256 amount_)
        internal
        view
        returns (uint256 underlyingAmount)
    {
        address priceOracle = PlasmaVaultLib.getPriceOracleMiddleware();
        if (priceOracle == address(0)) revert RWAErrors.RWAPriceOracleNotSet();

        (uint256 assetPrice, uint256 assetPriceDecimals) = IPriceOracleMiddleware(priceOracle).getAssetPrice(asset_);
        if (assetPrice == 0) revert RWAErrors.RWAInvalidPrice(asset_);

        address underlying = IERC4626(address(this)).asset();
        (uint256 underlyingPrice, uint256 underlyingPriceDecimals) =
            IPriceOracleMiddleware(priceOracle).getAssetPrice(underlying);
        if (underlyingPrice == 0) revert RWAErrors.RWAInvalidPrice(underlying);

        uint256 assetDecimals = IERC20Metadata(asset_).decimals();
        uint256 underlyingDecimals = IERC20Metadata(underlying).decimals();

        // USD (in 1e18 WAD): amount * assetPrice scaled to 18 = WAD(USD)
        uint256 usdWad = IporMath.convertToWad(amount_ * assetPrice, assetDecimals + assetPriceDecimals);

        // underlying price normalized to WAD
        uint256 underlyingPriceWad = IporMath.convertToWad(underlyingPrice, underlyingPriceDecimals);

        underlyingAmount = (usdWad * (10 ** underlyingDecimals)) / underlyingPriceWad;
    }
}
