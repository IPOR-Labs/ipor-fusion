// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IPlasmaVaultGovernance} from "../../interfaces/IPlasmaVaultGovernance.sol";
import {IRewardsRouter} from "../../interfaces/IRewardsRouter.sol";
import {Roles} from "../../libraries/Roles.sol";

/// @title RewardsRouter
/// @notice Generic, per-vault batched router that lets a rewards operator (the alpha/keeper) perform a
/// full rewards "claim (+ redeem/swap) -> vest" flow against the Fusion RewardsClaimManager in a single
/// transaction, instead of many separate keeper transactions.
///
/// @dev Security model — the router is deliberately powerless beyond rewards:
/// - It is permanently bound at construction to ONE PlasmaVault and its IporFusionAccessManager, both held
///   as `immutable` (the router is deployed directly per vault — no clones/proxies).
/// - {execute} is NOT gated by the AccessManager's per-selector mapping. Instead it self-checks that
///   `msg.sender` holds ALPHA_ROLE on the access manager (the keeper/alpha).
/// - To actually perform the batched calls, the router itself must hold the three rewards roles
///   (CLAIM_REWARDS_ROLE, TRANSFER_REWARDS_ROLE, UPDATE_REWARDS_BALANCE_ROLE), so that
///   RewardsClaimManager.{claimRewards,transfer,updateBalance} (each `restricted`) accept it as caller.
/// - RewardsClaimManager.transfer refuses to move the vault's underlying asset, so the vault's base capital
///   can never be pulled out of the rewards domain through this router.
///
/// Calls are fully generic (target + data); safety comes from the role limitation above, NOT from a target
/// allow-list. The router is not meant to custody funds between batches.
contract RewardsRouter is IRewardsRouter {
    using SafeERC20 for IERC20;
    using Address for address;

    /// @notice The PlasmaVault this router is permanently bound to.
    address public immutable override PLASMA_VAULT;

    /// @notice The IporFusionAccessManager this router is permanently bound to.
    address public immutable override ACCESS_MANAGER;

    /// @notice Emitted once per successful {execute} batch.
    /// @param caller The account that invoked {execute}.
    /// @param callsCount The number of calls executed in the batch.
    event BatchExecuted(address caller, uint256 callsCount);

    /// @notice Emitted on a successful {rescue}.
    /// @param asset The ERC20 token swept.
    /// @param to The recipient of the swept balance.
    /// @param amount The amount swept.
    event Rescued(address asset, address to, uint256 amount);

    /// @notice Emitted on a successful {transferAll}.
    /// @param asset The ERC20 token flushed.
    /// @param to The recipient of the flushed balance.
    /// @param amount The amount flushed (the router's full balance at call time).
    event TransferredAll(address asset, address to, uint256 amount);

    /// @notice Thrown when a required address argument is the zero address.
    error ZeroAddress();

    /// @notice Thrown when {execute} is called by an account that does not hold ALPHA_ROLE.
    error NotAlpha(address caller);

    /// @notice Thrown when {rescue} is called by an account that does not hold ATOMIST_ROLE.
    error NotAtomist(address caller);

    /// @notice Thrown when {execute} is called with an empty batch.
    error EmptyCalls();

    /// @notice Thrown when a call in the batch targets the zero address.
    /// @param index The index of the offending call.
    error ZeroTarget(uint256 index);

    /// @notice Thrown when {transferAll} is invoked by anyone other than the router itself.
    error NotSelf();

    /// @param plasmaVault_ The PlasmaVault to bind this router to permanently. The access manager is
    /// resolved from it and both are stored as immutables.
    constructor(address plasmaVault_) {
        if (plasmaVault_ == address(0)) revert ZeroAddress();

        address accessManager = IPlasmaVaultGovernance(plasmaVault_).getAccessManagerAddress();
        if (accessManager == address(0)) revert ZeroAddress();

        PLASMA_VAULT = plasmaVault_;
        ACCESS_MANAGER = accessManager;
    }

    /// @notice Executes a batch of calls in a single transaction, in order.
    /// @param calls_ The ordered list of calls to execute.
    /// @return results The raw return data of each call, in the same order.
    /// @dev Authorization is in-contract: `msg.sender` must hold ALPHA_ROLE on the bound access manager.
    /// Each call bubbles up reverts and rejects non-contract targets.
    function execute(ExecuteCall[] calldata calls_) external returns (bytes[] memory results) {
        if (!_hasRole(Roles.ALPHA_ROLE, msg.sender)) revert NotAlpha(msg.sender);

        uint256 len = calls_.length;
        if (len == 0) revert EmptyCalls();

        results = new bytes[](len);
        for (uint256 i; i < len; ++i) {
            address target = calls_[i].target;
            if (target == address(0)) revert ZeroTarget(i);

            results[i] = target.functionCall(calls_[i].data);
        }

        emit BatchExecuted(msg.sender, len);
    }

    /// @notice Transfers the router's ENTIRE balance of `asset_` to `to_`.
    /// @dev Self-call only: reachable solely as a step inside {execute} (where each sub-call runs with
    /// `msg.sender == address(this)`), so it inherits execute's ALPHA gate while never being callable
    /// directly. This lets a batch vest exactly what the swaps produced — there is no off-chain amount to
    /// pin, so the batch can neither revert from over-estimating the swap output nor strand dust from
    /// under-estimating it (and any leftover dust from a previous batch is swept in the same call). It only
    /// ever moves the router's own (transient/post-swap) balance, so it cannot reach the vault's base capital.
    /// @param asset_ The ERC20 to flush (e.g. the vault main asset, right before RewardsClaimManager.updateBalance()).
    /// @param to_ The recipient of the full balance (e.g. the RewardsClaimManager).
    function transferAll(address asset_, address to_) external override {
        if (msg.sender != address(this)) revert NotSelf();
        if (to_ == address(0)) revert ZeroAddress();

        uint256 amount = IERC20(asset_).balanceOf(address(this));
        IERC20(asset_).safeTransfer(to_, amount);

        emit TransferredAll(asset_, to_, amount);
    }

    /// @notice Sweeps ERC20 tokens accidentally left on this router.
    /// @dev Recovery hatch only — the router is not meant to custody funds between batches. Authorization is
    /// in-contract: `msg.sender` must hold ATOMIST_ROLE on the bound access manager.
    /// @param asset_ The ERC20 token to sweep.
    /// @param to_ The recipient of the swept balance.
    /// @param amount_ The amount to sweep.
    function rescue(address asset_, address to_, uint256 amount_) external {
        if (!_hasRole(Roles.ATOMIST_ROLE, msg.sender)) revert NotAtomist(msg.sender);
        if (to_ == address(0)) revert ZeroAddress();

        IERC20(asset_).safeTransfer(to_, amount_);

        emit Rescued(asset_, to_, amount_);
    }

    /// @dev True iff `account_` currently holds `role_` on the bound access manager.
    function _hasRole(uint64 role_, address account_) private view returns (bool isMember) {
        (isMember, ) = IAccessManager(ACCESS_MANAGER).hasRole(role_, account_);
    }
}
