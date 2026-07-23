// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Errors} from "../../libraries/errors/Errors.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../libraries/PlasmaVaultStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IExtTermController} from "./ext/IExtTermController.sol";
import {IExtTermRepoCollateralManager} from "./ext/IExtTermRepoCollateralManager.sol";
import {IExtTermRepoServicer} from "./ext/IExtTermRepoServicer.sol";
import {TermFinanceSubstrateLib} from "./lib/TermFinanceSubstrateLib.sol";

/// @notice Data for locking a single collateral position via TermRepoCollateralManager.
/// @param servicer Substrate key — TermRepoServicer proxy of the target Term Repo.
/// @param collateralManager TermRepoCollateralManager proxy of the target Term Repo;
///        validated against `IExtTermRepoServicer(servicer).termRepoCollateralManager()`
///        (impersonation guard).
/// @param collateralToken Allowlisted collateral token address; validated against
///        `TermFinanceSubstrateLib.collateralPairKey(servicer, collateralToken)` AND
///        against the on-chain accepted-collateral list of `collateralManager`.
/// @param amount Raw token units of `collateralToken` to lock.
struct TermFinanceCollateralFuseEnterData {
    address servicer;
    address collateralManager;
    address collateralToken;
    uint256 amount;
}

/// @notice Data for unlocking a single collateral position (post-clearing draw-down).
/// @param servicer Substrate key — TermRepoServicer proxy of the target Term Repo.
/// @param collateralManager TermRepoCollateralManager proxy of the target Term Repo;
///        validated against `IExtTermRepoServicer(servicer).termRepoCollateralManager()`
///        (impersonation guard).
/// @param collateralToken Allowlisted collateral token address; validated against
///        `TermFinanceSubstrateLib.collateralPairKey(servicer, collateralToken)` AND
///        against the on-chain accepted-collateral list of `collateralManager`.
/// @param amount Raw token units of `collateralToken` to unlock.
struct TermFinanceCollateralFuseExitData {
    address servicer;
    address collateralManager;
    address collateralToken;
    uint256 amount;
}

/// @title TermFinanceCollateralFuse
/// @author IPOR Labs
/// @notice Lock and unlock borrower collateral positions on Term Finance.
/// @dev The fuse exposes the simplest borrower-side action: pulling collateral ERC20s from
///      the PlasmaVault into a Term `TermRepoCollateralManager` (enter) and pulling them
///      back out before / after clearing (exit). The substrate model uses the typed
///      `TermFinanceSubstrateLib` encoding: servicer addresses live under
///      `TermFinanceSubstrateType.SERVICER` (upper byte 0x00), and (servicer, collateralToken)
///      pairs live under `TermFinanceSubstrateType.COLLATERAL_TOKEN` (upper byte 0x01).
///
///      Approval flow mirrors `TermFinanceOfferFuse`: the approval target is the per-Term
///      `TermRepoLocker` (resolved via `IExtTermRepoServicer(servicer).termRepoLocker()`),
///      NOT the `TermRepoCollateralManager` itself — `externalLockCollateral` pulls the
///      collateral via `TermRepoLocker.transferTokenFromWallet(borrower, ...)`. See
///      `IExtTermRepoCollateralManager.externalLockCollateral` NatSpec and the live-impl
///      verification.
///
///      WithdrawManager check: `_assertWithdrawManagerSet()` runs as the FIRST statement
///      of BOTH `enter` and `exit`. The check is NOT in the constructor because
///      `PlasmaVaultStorageLib.getWithdrawManager()` reads the deployer's storage during
///      construction (delegatecall context is not available at deploy time), so a
///      constructor check would revert universally. Codifies the non-negotiable invariant
///      that a vault without a WithdrawManager could allow withdrawals at any time,
///      bypassing the Term Finance maturity timeline and underwatering the vault. Mirror
///      of the `BurnRequestFeeFuse.enter` worktree pattern.
///
///      Servicer deployment guard: every `enter` / `exit` calls
///      `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` as step 2 of the
///      validation pipeline (after the IPOR-side substrate allowlist, before the
///      servicer-side pairing check). The Term Finance `TermController` is the evergreen
///      registry of all deployed Term Repos; rejecting servicers that the controller does
///      not recognise blocks impersonation by lookalike contracts even if the substrate
///      allowlist was misconfigured upstream. Mirror of `TermFinanceOfferFuse._assertServicerAllowed`.
contract TermFinanceCollateralFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    /// @notice Emitted when collateral is successfully locked via `externalLockCollateral`.
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer substrate associated with the position.
    /// @param collateralManager TermRepoCollateralManager paired with `servicer`.
    /// @param collateralToken Collateral ERC20 token that was locked.
    /// @param amount Raw token units that were locked.
    event TermFinanceCollateralLocked(
        address version,
        address servicer,
        address collateralManager,
        address collateralToken,
        uint256 amount
    );

    /// @notice Emitted when collateral is successfully unlocked via `externalUnlockCollateral`.
    /// @param version Address of this fuse instance (event-only version tag).
    /// @param servicer TermRepoServicer substrate associated with the position.
    /// @param collateralManager TermRepoCollateralManager paired with `servicer`.
    /// @param collateralToken Collateral ERC20 token that was unlocked.
    /// @param amount Raw token units that were unlocked.
    event TermFinanceCollateralUnlocked(
        address version,
        address servicer,
        address collateralManager,
        address collateralToken,
        uint256 amount
    );

    /// @notice Reverts when the PlasmaVault has no WithdrawManager configured.
    /// @dev Codifies the non-functional requirement: a vault without a WithdrawManager
    ///      could allow withdrawals at any time, bypassing the Term Finance maturity timeline.
    error TermFinanceCollateralFuseWithdrawManagerRequired();

    /// @notice Reverts when `servicer` is not in the vault's `TERM_FINANCE` market
    ///         substrate allowlist (as a `SERVICER`-typed substrate).
    /// @param servicer The non-allowlisted servicer that was passed in calldata.
    error TermFinanceCollateralFuseUnsupportedMarket(address servicer);

    /// @notice Reverts when the `(servicer, collateralToken)` pair is not in the vault's
    ///         `TERM_FINANCE` market substrate allowlist as a `COLLATERAL_TOKEN`-typed substrate.
    /// @param collateralToken The non-allowlisted collateral token that was passed in calldata.
    error TermFinanceCollateralFuseUnsupportedCollateralToken(address collateralToken);

    /// @notice Reverts when `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)`
    ///         returns false — i.e. the Term Finance evergreen controller does not recognise
    ///         `servicer` as a live, deployed `TermRepoServicer`.
    /// @param servicer The servicer address that failed the controller deployment check.
    error TermFinanceCollateralFuseTermNotDeployed(address servicer);

    /// @notice Reverts when `IExtTermRepoServicer(servicer).termRepoCollateralManager()` does
    ///         not match the `collateralManager` supplied in calldata (impersonation guard).
    /// @param servicer The servicer whose pairing was checked.
    /// @param expected The collateralManager returned by the servicer.
    /// @param actual The collateralManager supplied via calldata.
    error TermFinanceCollateralFuseServicerCollateralManagerMismatch(
        address servicer,
        address expected,
        address actual
    );

    /// @notice Reverts when the supplied `collateralToken` is NOT in the
    ///         `collateralManager.collateralTokens(...)` accepted-list.
    /// @param collateralManager The TermRepoCollateralManager whose accepted list was inspected.
    /// @param collateralToken The collateral token that failed the accepted-list check.
    error TermFinanceCollateralFuseCollateralTokenNotAccepted(address collateralManager, address collateralToken);

    /// @notice Reverts when `enter` or `exit` is called with `amount == 0`.
    error TermFinanceCollateralFuseZeroAmount();

    /// @notice Address of this contract instance, used as the version identifier in event logs.
    address public immutable VERSION;

    /// @notice PlasmaVault market id assigned to Term Finance.
    uint256 public immutable MARKET_ID;

    /// @notice Live Term Finance `TermController` proxy used to verify that each servicer
    ///         passed in calldata is a Term-recognised deployment.
    address public immutable TERM_CONTROLLER;

    /// @notice Initialise immutables.
    /// @dev `marketId_ > 0` and `termController_ != address(0)` are required; market id 0
    ///      is the sentinel for "unconfigured", and a zero controller would silently disable
    ///      the per-call `isTermDeployed` guard.
    ///      The WithdrawManager check is intentionally NOT performed here — see contract
    ///      NatSpec for the rationale (delegatecall context unavailable at deploy time).
    /// @param marketId_ PlasmaVault market id assigned to Term Finance.
    /// @param termController_ Term Finance evergreen `TermController` proxy address.
    constructor(uint256 marketId_, address termController_) {
        if (marketId_ == 0) revert Errors.WrongValue();
        if (termController_ == address(0)) revert Errors.WrongAddress();

        VERSION = address(this);
        MARKET_ID = marketId_;
        TERM_CONTROLLER = termController_;
    }

    /// @notice Lock additional borrower collateral on a Term Finance Repo.
    /// @dev Validation order (all-or-nothing; any failure reverts atomically):
    ///      0. `_assertWithdrawManagerSet()` — non-negotiable runtime invariant.
    ///      1. Servicer substrate allowlist (typed `SERVICER`).
    ///      2. `(servicer, collateralToken)` substrate allowlist (typed `COLLATERAL_TOKEN`).
    ///      3. `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` — Term Finance
    ///         evergreen controller deployment guard.
    ///      4. Servicer-side pairing: `servicer.termRepoCollateralManager() == data_.collateralManager`.
    ///      5. CollateralManager-side acceptance: `collateralToken` is enumerated in
    ///         `collateralManager.collateralTokens(...)` (defense-in-depth — the substrate
    ///         allowlist captures IPOR-side policy; this check captures Term-side policy).
    ///      6. `amount > 0`.
    ///      7. `forceApprove(termRepoLocker, amount)` — approval target is the per-Term
    ///         `TermRepoLocker`, NOT the CollateralManager (see contract NatSpec).
    ///      8. `externalLockCollateral(collateralToken, amount)` on the CollateralManager.
    ///      9. `forceApprove(termRepoLocker, 0)` — defensive cleanup. `externalLockCollateral`
    ///         is expected to consume exactly `amount`, but the reset guards against any
    ///         future impl that partial-pulls.
    ///     10. Emit `TermFinanceCollateralLocked`.
    /// @param data_ Calldata struct — see `TermFinanceCollateralFuseEnterData` NatSpec.
    function enter(TermFinanceCollateralFuseEnterData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertSubstrates(data_.servicer, data_.collateralToken);
        _assertServicerTermDeployed(data_.servicer);
        _assertServicerCollateralManagerPaired(data_.servicer, data_.collateralManager);
        _assertCollateralTokenAccepted(data_.collateralManager, data_.collateralToken);
        if (data_.amount == 0) revert TermFinanceCollateralFuseZeroAmount();

        address termRepoLocker = IExtTermRepoServicer(data_.servicer).termRepoLocker();

        ERC20(data_.collateralToken).forceApprove(termRepoLocker, data_.amount);

        IExtTermRepoCollateralManager(data_.collateralManager).externalLockCollateral(
            data_.collateralToken,
            data_.amount
        );

        ERC20(data_.collateralToken).forceApprove(termRepoLocker, 0);

        emit TermFinanceCollateralLocked(
            VERSION,
            data_.servicer,
            data_.collateralManager,
            data_.collateralToken,
            data_.amount
        );
    }

    /// @notice Unlock previously-locked borrower collateral on a Term Finance Repo.
    /// @dev Validation order:
    ///      0. `_assertWithdrawManagerSet()`.
    ///      1. Servicer substrate allowlist (typed `SERVICER`).
    ///      2. `(servicer, collateralToken)` substrate allowlist (typed `COLLATERAL_TOKEN`).
    ///      3. `IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer)` — Term Finance
    ///         evergreen controller deployment guard.
    ///      4. Servicer-side pairing check.
    ///      5. CollateralManager-side acceptance check.
    ///      6. `amount > 0`.
    ///      7. `externalUnlockCollateral(collateralToken, amount)` — no approval needed
    ///         because tokens flow OUT of the locker back to the vault.
    ///      8. Emit `TermFinanceCollateralUnlocked`.
    ///
    ///      The CollateralManager enforces the maintenance-margin invariant on this call;
    ///      attempts to unlock below the maintenance ratio revert at the Term layer.
    /// @param data_ Calldata struct — see `TermFinanceCollateralFuseExitData` NatSpec.
    function exit(TermFinanceCollateralFuseExitData calldata data_) external {
        _assertWithdrawManagerSet();
        _assertSubstrates(data_.servicer, data_.collateralToken);
        _assertServicerTermDeployed(data_.servicer);
        _assertServicerCollateralManagerPaired(data_.servicer, data_.collateralManager);
        _assertCollateralTokenAccepted(data_.collateralManager, data_.collateralToken);
        if (data_.amount == 0) revert TermFinanceCollateralFuseZeroAmount();

        IExtTermRepoCollateralManager(data_.collateralManager).externalUnlockCollateral(
            data_.collateralToken,
            data_.amount
        );

        emit TermFinanceCollateralUnlocked(
            VERSION,
            data_.servicer,
            data_.collateralManager,
            data_.collateralToken,
            data_.amount
        );
    }

    /// @notice Reverts unless the vault has a WithdrawManager configured.
    /// @dev See contract NatSpec for rationale. Read directly from the canonical storage
    ///      slot via `PlasmaVaultStorageLib.getWithdrawManager()` — during fuse delegatecall
    ///      the slot is read from PlasmaVault storage (the intended context).
    function _assertWithdrawManagerSet() private view {
        if (PlasmaVaultStorageLib.getWithdrawManager().manager == address(0)) {
            revert TermFinanceCollateralFuseWithdrawManagerRequired();
        }
    }

    /// @notice Reverts unless BOTH the servicer (TYPE 0x00) and the
    ///         (servicer, collateralToken) pair (TYPE 0x01) are in the market substrate
    ///         allowlist.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param collateralToken_ Collateral ERC20 address.
    function _assertSubstrates(address servicer_, address collateralToken_) private view {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, servicer_)) {
            revert TermFinanceCollateralFuseUnsupportedMarket(servicer_);
        }

        bytes32 pairKey = TermFinanceSubstrateLib.collateralPairKey(servicer_, collateralToken_);
        if (!PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, pairKey)) {
            revert TermFinanceCollateralFuseUnsupportedCollateralToken(collateralToken_);
        }
    }

    /// @notice Reverts unless the Term Finance evergreen `TermController` recognises
    ///         `servicer_` as a deployed `TermRepoServicer`.
    /// @dev Mirror of `TermFinanceOfferFuse._assertServicerAllowed` and
    ///      `TermFinanceRedeemFuse.enter` — keeps the borrower-side fuses aligned with the
    ///      lender-side controller guard, blocking lookalike contracts that pass the IPOR
    ///      substrate allowlist but are not Term-deployed.
    /// @param servicer_ TermRepoServicer proxy address.
    function _assertServicerTermDeployed(address servicer_) private view {
        if (!IExtTermController(TERM_CONTROLLER).isTermDeployed(servicer_)) {
            revert TermFinanceCollateralFuseTermNotDeployed(servicer_);
        }
    }

    /// @notice Reverts unless `servicer_.termRepoCollateralManager()` matches the
    ///         `collateralManager_` supplied in calldata (impersonation guard).
    /// @dev Without this check, an alpha could pass a forged `collateralManager` exposing
    ///      the same selectors and divert approvals to it.
    /// @param servicer_ TermRepoServicer proxy address.
    /// @param collateralManager_ TermRepoCollateralManager address from calldata.
    function _assertServicerCollateralManagerPaired(address servicer_, address collateralManager_) private view {
        address expected = IExtTermRepoServicer(servicer_).termRepoCollateralManager();
        if (expected != collateralManager_) {
            revert TermFinanceCollateralFuseServicerCollateralManagerMismatch(
                servicer_,
                expected,
                collateralManager_
            );
        }
    }

    /// @notice Reverts unless `collateralToken_` appears in the accepted-collateral list
    ///         of `collateralManager_`.
    /// @dev Iterates `collateralManager_.collateralTokens(i)` bounded by
    ///      `numOfAcceptedCollateralTokens()` (returns `uint8` — verified live, see the
    ///      `IExtTermRepoCollateralManager.numOfAcceptedCollateralTokens` NatSpec).
    ///      The accepted-list is part of the Term Repo configuration and is set at deploy
    ///      time; iteration cost is bounded by Term's own design (current impls have
    ///      <= 8 collateral tokens). Defense-in-depth on top of the IPOR substrate allowlist.
    /// @param collateralManager_ TermRepoCollateralManager proxy address.
    /// @param collateralToken_ Collateral ERC20 address to check.
    function _assertCollateralTokenAccepted(address collateralManager_, address collateralToken_) private view {
        IExtTermRepoCollateralManager cm = IExtTermRepoCollateralManager(collateralManager_);
        uint8 n = cm.numOfAcceptedCollateralTokens();

        for (uint256 i; i < n; ++i) {
            if (cm.collateralTokens(i) == collateralToken_) {
                return;
            }
        }

        revert TermFinanceCollateralFuseCollateralTokenNotAccepted(collateralManager_, collateralToken_);
    }
}
