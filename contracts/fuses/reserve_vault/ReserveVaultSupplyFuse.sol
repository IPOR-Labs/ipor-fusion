// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IPlasmaVault} from "../../interfaces/IPlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {ReserveVaultStorageLib} from "./lib/ReserveVaultStorageLib.sol";
import {ReserveVaultBoostLib} from "./lib/ReserveVaultBoostLib.sol";

/// @notice Data structure for entering - depositing into - a member vault
struct ReserveVaultSupplyFuseEnterData {
    /// @dev Member vault (a Plasma Vault granted as a substrate of `MARKET_ID`)
    address vault;
    /// @dev Amount of the member vault's asset to deposit
    uint256 amount;
}

/// @notice Data structure for exiting - withdrawing principal from - a member vault
struct ReserveVaultSupplyFuseExitData {
    /// @dev Member vault (a Plasma Vault granted as a substrate of `MARKET_ID`)
    address vault;
    /// @dev Amount of the member vault's asset to withdraw; at most the principal recorded for the member vault
    uint256 amount;
}

/// @title ReserveVaultSupplyFuse
/// @notice Lends the reserve vault's assets to member vaults and takes back exactly the principal, whatever the member
///         vault's exchange rate is, as long as the member vault holds the funds idle
/// @dev Runs by delegatecall in the reserve vault (C), managed by C's Alpha through `C.execute`. A member vault (A) is a
///      substrate of `MARKET_ID`. `enter` deposits into A and records the deposited amount as principal in C's storage
///      (`ReserveVaultStorageLib`). `exit` withdraws at most that principal:
///      - when C's whole position in A is worth less than its whole principal, C stores a transient boost X for A
///        (`ReserveVaultBoostLib`), refreshes A's market `BOOST_MARKET_ID` (A's boost balance fuse reads X back
///        through C's UniversalReader and adds it to A's assets), withdraws, clears X and refreshes that market again;
///      - when the principal reaches zero and C still holds A shares, C redeems them and sends the assets received back
///        to A with `safeTransfer`. This happens only on the exit that brings the principal to zero, but on every such
///        exit that leaves shares: in profit (the surplus), and also flat or at a loss, where the leftover is rounding
///        dust that may be worth 0 assets (a redeem and a transfer of 0 assets).
/// @dev Liquidity rule. A must not pull liquidity from its markets (in particular not from C) during C's exit. Before
///      `withdraw` and before the surplus `redeem` the fuse mirrors A's own thresholds for a market pull (see
///      `MEMBER_VAULT_WITHDRAW_OFFSET` and `MEMBER_VAULT_REDEEM_SLIPPAGE_IN_PERCENTAGE`) and reverts with
///      `ReserveVaultSupplyFuseInsufficientIdleLiquidity` when A would pull. These checks read A's state before A's own
///      pre-hooks run. The hard guarantee is the final check: A's asset balance after the exit must equal its balance
///      before the exit minus `amount`, otherwise `ReserveVaultSupplyFuseIdleBalanceMismatch`. A pull that moved funds
///      therefore reverts the exit; a pull attempt that brought no funds is not visible to this check.
/// @dev Assumptions, not checks. The fuse reads neither A's fees, hooks, WithdrawManager, dependency graph nor the
///      substrates of other markets, and it does not verify that A booked the boost. The configuration must ensure:
///      - zero fees on member vaults: performance, management (including the DAO part), withdraw and deposit fees;
///      - C holds `UPDATE_MARKETS_BALANCES_ROLE` and the whitelist role on A;
///      - C is exempt from A's redemption delay;
///      - A has no withdrawal request flow (instant withdrawals only, no released request shares);
///      - A is a Plasma Vault that runs a generation of the code with the same pull thresholds in `withdraw` and
///        `redeem`, and that does not check market limits on a balance refresh by `updateMarketsBalances`; older
///        generations check them on every refresh, so the first boost refresh would revert there, because the boost
///        market has a default limit of 0%;
///      - the asset of A transfers exact amounts: no fee-on-transfer, no rebasing and no stETH-style rounding of a
///        transfer by a wei or two, and it accepts zero-value transfers (the surplus step can transfer 0);
///      - A has a market `BOOST_MARKET_ID` with the reserve vault boost balance fuse and C as its substrate, and that
///        market has no dependency graph edge;
///      - the chain supports transient storage (Cancun, EIP-1153).
/// @dev Known limitation, not guarded. Inside one exit, between `A.withdraw` and the surplus `A.redeem`, C already holds
///      the withdrawn principal while its stored balance of `MARKET_ID` is stale until the end of `C.execute`, so C's
///      share price is transiently inflated by `amount`. The surplus `A.redeem` runs on every full exit that leaves
///      shares (in profit, flat or at a loss), so this applies to all of them, not only to a profitable one. When A
///      holds C shares and has a pre-hook on `redeem` that
///      refreshes its markets, that `redeem` stores an inflated value of A's position in C, which stays in A until the
///      next refresh of that market. A separate reserve batch does not avoid it; the operator either has that
///      refreshing hook on every A selector priced by the share rate, or refreshes A's market holding C shares after
///      the reserve action. See the family README.
/// @dev Not an instant-withdraw fuse: it does not implement `IFuseInstantWithdraw` and must never be put on C's
///      instant-withdraw list.
/// @author IPOR Labs
contract ReserveVaultSupplyFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice Emitted when the reserve vault deposits into a member vault
    /// @param version The address of this fuse contract version
    /// @param vault The member vault
    /// @param asset The member vault's asset
    /// @param amount The amount of the asset deposited, measured as the decrease of the reserve vault's balance
    /// @param shares The member vault shares received
    /// @param principal The principal recorded for the member vault after the deposit
    event ReserveVaultSupplyFuseEnter(
        address version,
        address vault,
        address asset,
        uint256 amount,
        uint256 shares,
        uint256 principal
    );

    /// @notice Emitted when the reserve vault withdraws principal from a member vault
    /// @param version The address of this fuse contract version
    /// @param vault The member vault
    /// @param asset The member vault's asset
    /// @param amount The amount of the asset withdrawn, exactly the requested amount
    /// @param sharesBurned All member vault shares burned by this exit: by `withdraw` and by the surplus `redeem`
    /// @param boost The transient boost set for the member vault during the withdrawal, 0 when none was needed
    /// @param surplusAssets The assets received from the surplus `redeem` and sent back to the member vault, 0 when
    ///        nothing was redeemed
    /// @param principal The principal recorded for the member vault after the exit
    event ReserveVaultSupplyFuseExit(
        address version,
        address vault,
        address asset,
        uint256 amount,
        uint256 sharesBurned,
        uint256 boost,
        uint256 surplusAssets,
        uint256 principal
    );

    /// @notice Thrown when the vault is not granted as a substrate of `MARKET_ID`
    /// @param action The action, "enter" or "exit"
    /// @param vault The vault
    error ReserveVaultSupplyFuseUnsupportedVault(string action, address vault);

    /// @notice Thrown when an exit asks for more than the principal recorded for the member vault
    /// @param vault The member vault
    /// @param amount The requested amount
    /// @param principal The principal recorded for the member vault
    error ReserveVaultSupplyFuseAmountExceedsPrincipal(address vault, uint256 amount, uint256 principal);

    /// @notice Thrown when the reserve vault holds no member vault shares while principal is recorded: at the start of
    ///         an exit, or when an exit would leave principal without shares
    /// @param vault The member vault
    /// @param principal The principal recorded for the member vault
    error ReserveVaultSupplyFuseNoShares(address vault, uint256 principal);

    /// @notice Thrown when the member vault's idle assets are not above the threshold at which it would pull from its
    ///         markets
    /// @param vault The member vault
    /// @param idle The member vault's balance of its asset
    /// @param required The threshold; the exit needs `idle > required`
    error ReserveVaultSupplyFuseInsufficientIdleLiquidity(address vault, uint256 idle, uint256 required);

    /// @notice Thrown when the member vault's asset balance after the exit is not its balance before minus the amount
    /// @param vault The member vault
    /// @param expected The expected balance: balance before the exit minus the amount
    /// @param actual The member vault's balance of its asset after the exit
    error ReserveVaultSupplyFuseIdleBalanceMismatch(address vault, uint256 expected, uint256 actual);

    /// @dev Mirror of `PlasmaVault.WITHDRAW_FROM_MARKETS_OFFSET`. Without released request shares,
    ///      `PlasmaVault.withdraw(assets)` pulls from its markets with `assets + WITHDRAW_FROM_MARKETS_OFFSET`, and
    ///      `_withdrawFromMarkets` pulls when that value is greater than or equal to the vault's idle balance.
    ///      The withdrawal stays on idle assets only when `idle > amount + 10`.
    uint256 private constant MEMBER_VAULT_WITHDRAW_OFFSET = 10;

    /// @dev Mirror of `PlasmaVault.DEFAULT_SLIPPAGE_IN_PERCENTAGE`. Without released request shares,
    ///      `PlasmaVault.redeem(shares)` pulls from its markets with `value + value * 2 / 100`,
    ///      `value = convertToAssets(shares)` (`_redeem` and `_includeSlippage`, floor division), when that value is
    ///      non-zero and greater than or equal to the vault's idle balance (`_withdrawFromMarkets`).
    uint256 private constant MEMBER_VAULT_REDEEM_SLIPPAGE_IN_PERCENTAGE = 2;

    /// @notice The address of this fuse contract version
    address public immutable VERSION;

    /// @notice The reserve vault market of this fuse; its substrates are the member vaults
    uint256 public immutable MARKET_ID;

    /// @notice The member vault market refreshed during a boosted exit (the market of the reserve vault boost balance
    ///         fuse in the member vault)
    uint256 public immutable BOOST_MARKET_ID;

    /// @notice Sets the fuse version and the market ids
    /// @param marketId_ The reserve vault market of this fuse
    /// @param boostMarketId_ The member vault market refreshed during a boosted exit
    constructor(uint256 marketId_, uint256 boostMarketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        BOOST_MARKET_ID = boostMarketId_;
    }

    /// @notice Deposits the reserve vault's assets into a member vault and records them as principal
    /// @dev `amount == 0` is a no-op. The amount is not clamped to the reserve vault's balance (the deposit reverts when
    ///      the balance is too low) and there is no minimum of shares: the shares do not limit the principal that can be
    ///      taken back as long as they are non-zero, and a Plasma Vault reverts a deposit that mints zero shares
    ///      (`NoSharesToDeposit`). The principal grows by the measured decrease of the
    ///      reserve vault's balance, which the allowance caps at `amount`; any allowance left after the deposit is
    ///      reset to zero.
    /// @param data_ The member vault and the amount of its asset to deposit
    function enter(ReserveVaultSupplyFuseEnterData calldata data_) external {
        address vault = data_.vault;
        uint256 amount = data_.amount;

        if (amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, vault)) {
            revert ReserveVaultSupplyFuseUnsupportedVault("enter", vault);
        }

        address asset = IERC4626(vault).asset();
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        IERC20(asset).forceApprove(vault, amount);

        uint256 shares = IERC4626(vault).deposit(amount, address(this));

        uint256 deposited = balanceBefore - IERC20(asset).balanceOf(address(this));
        uint256 principal = ReserveVaultStorageLib.increasePrincipal(vault, deposited);

        if (IERC20(asset).allowance(address(this), vault) != 0) {
            IERC20(asset).forceApprove(vault, 0);
        }

        emit ReserveVaultSupplyFuseEnter(VERSION, vault, asset, deposited, shares, principal);
    }

    /// @notice Withdraws exactly `amount` of principal from a member vault
    /// @dev Notation: P = principal, s = the reserve vault's shares in the member vault, G = the member vault's
    ///      `totalAssets()`, D = its `convertToShares(G + 1)` (supply plus virtual shares). Sequence:
    ///      1. `amount == 0` is a no-op; the vault must be a granted substrate; `amount > P` reverts (no clamp, no
    ///         "max" value); `s == 0` reverts with `ReserveVaultSupplyFuseNoShares`.
    ///      2. Liquidity precondition for `withdraw`: revert when the member vault's idle balance is not above
    ///         `amount + 10` (see `MEMBER_VAULT_WITHDRAW_OFFSET`). Nothing has changed up to here.
    ///      3. Boost X = `ReserveVaultBoostLib.computeBoost(P, s, G, D)`, the smallest amount that makes all s shares
    ///         worth P; it is 0 when the whole position already covers the whole principal. When X > 0, X is stored in
    ///         transient storage and the member vault's `BOOST_MARKET_ID` is refreshed.
    ///      4. `withdraw(amount)` to the reserve vault.
    ///      5. When boosted: X is cleared and `BOOST_MARKET_ID` is refreshed again. Between steps 3 and 5 there is no
    ///         try/catch and no early return: any failure reverts the whole exit, transient value included.
    ///      6. The principal decreases by `amount`.
    ///      7. When the principal is zero and shares remain (the surplus): liquidity precondition for `redeem` (see
    ///         `MEMBER_VAULT_REDEEM_SLIPPAGE_IN_PERCENTAGE`), `redeem` of all remaining shares, and the measured
    ///         increase of the reserve vault's balance is sent back to the member vault with `safeTransfer`. This
    ///         runs after the transient boost is cleared.
    ///      8. Post-conditions: principal > 0 with zero shares left reverts with `ReserveVaultSupplyFuseNoShares` (such a
    ///         position could not be recovered by a later boost); the member vault's asset balance must equal its
    ///         balance before the exit minus `amount` (the surplus redeemed and sent back nets out), otherwise
    ///         `ReserveVaultSupplyFuseIdleBalanceMismatch`.
    ///      9. `ReserveVaultSupplyFuseExit` is emitted.
    /// @dev The fuse computes X itself; it is not an input and has no cap. A partial exit with a boost burns shares at
    ///      the boosted rate; the next exit computes X again from the remaining principal and shares.
    /// @param data_ The member vault and the amount of its asset to withdraw
    function exit(ReserveVaultSupplyFuseExitData calldata data_) external {
        address vault = data_.vault;
        uint256 amount = data_.amount;

        if (amount == 0) {
            return;
        }

        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, vault)) {
            revert ReserveVaultSupplyFuseUnsupportedVault("exit", vault);
        }

        uint256 principal = ReserveVaultStorageLib.getPrincipal(vault);

        if (amount > principal) {
            revert ReserveVaultSupplyFuseAmountExceedsPrincipal(vault, amount, principal);
        }

        address asset = IERC4626(vault).asset();
        uint256 idleBefore;
        uint256 boost;
        uint256 sharesBurned;

        {
            uint256 shares = IERC4626(vault).balanceOf(address(this));

            if (shares == 0) {
                revert ReserveVaultSupplyFuseNoShares(vault, principal);
            }

            idleBefore = IERC20(asset).balanceOf(vault);
            _checkIdleLiquidity(vault, idleBefore, amount + MEMBER_VAULT_WITHDRAW_OFFSET);

            (boost, sharesBurned) = _withdrawWithBoost(vault, amount, principal, shares);
        }

        principal = ReserveVaultStorageLib.decreasePrincipal(vault, amount);

        uint256 surplusAssets;

        if (principal == 0) {
            uint256 surplusShares;
            (surplusShares, surplusAssets) = _returnSurplus(vault, asset);
            sharesBurned += surplusShares;
        }

        _checkPostConditions(vault, asset, principal, idleBefore - amount);

        emit ReserveVaultSupplyFuseExit(VERSION, vault, asset, amount, sharesBurned, boost, surplusAssets, principal);
    }

    /// @notice Returns the principal that a reserve vault recorded for a member vault
    /// @dev Meant to run in the reserve vault's context, through its UniversalReader:
    ///      `UniversalReader(reserveVault).read(address(fuse), abi.encodeCall(ReserveVaultSupplyFuse.getPrincipal,
    ///      (memberVault)))`. Called directly on the fuse it reads the fuse's own storage and returns 0.
    /// @param vault_ The member vault
    /// @return The principal, in the member vault's asset
    function getPrincipal(address vault_) external view returns (uint256) {
        return ReserveVaultStorageLib.getPrincipal(vault_);
    }

    /// @notice Steps 3 to 5 of the exit: boost when needed, withdraw, clear the boost
    /// @param vault_ The member vault
    /// @param amount_ The amount to withdraw
    /// @param principal_ The principal before the exit
    /// @param shares_ The reserve vault's shares in the member vault before the exit, non-zero
    /// @return boost The boost set during the withdrawal, 0 when none was needed
    /// @return sharesBurned The shares burned by `withdraw`
    function _withdrawWithBoost(
        address vault_,
        uint256 amount_,
        uint256 principal_,
        uint256 shares_
    ) private returns (uint256 boost, uint256 sharesBurned) {
        uint256 totalAssets = IERC4626(vault_).totalAssets();

        boost = ReserveVaultBoostLib.computeBoost(
            principal_,
            shares_,
            totalAssets,
            IERC4626(vault_).convertToShares(totalAssets + 1)
        );

        if (boost > 0) {
            ReserveVaultBoostLib.setBoost(vault_, boost);
            _refreshBoostMarket(vault_);
        }

        sharesBurned = IERC4626(vault_).withdraw(amount_, address(this), address(this));

        if (boost > 0) {
            ReserveVaultBoostLib.clearBoost(vault_);
            _refreshBoostMarket(vault_);
        }
    }

    /// @notice Step 7 of the exit: redeems the shares left after the principal reached zero and sends the assets back
    /// @dev The liquidity precondition mirrors the member vault's `redeem` pull threshold, see
    ///      `MEMBER_VAULT_REDEEM_SLIPPAGE_IN_PERCENTAGE`. The value of the remaining shares is known only after the
    ///      withdrawal, so this check stands right before the `redeem`; its revert undoes the whole exit.
    /// @param vault_ The member vault
    /// @param asset_ The member vault's asset
    /// @return surplusShares The shares redeemed, 0 when none were left
    /// @return surplusAssets The assets received from the redeem and sent back to the member vault
    function _returnSurplus(
        address vault_,
        address asset_
    ) private returns (uint256 surplusShares, uint256 surplusAssets) {
        surplusShares = IERC4626(vault_).balanceOf(address(this));

        if (surplusShares == 0) {
            return (0, 0);
        }

        uint256 value = IERC4626(vault_).convertToAssets(surplusShares);
        _checkIdleLiquidity(
            vault_,
            IERC20(asset_).balanceOf(vault_),
            value + (value * MEMBER_VAULT_REDEEM_SLIPPAGE_IN_PERCENTAGE) / 100
        );

        uint256 balanceBefore = IERC20(asset_).balanceOf(address(this));

        IERC4626(vault_).redeem(surplusShares, address(this), address(this));

        surplusAssets = IERC20(asset_).balanceOf(address(this)) - balanceBefore;

        if (surplusAssets > 0) {
            IERC20(asset_).safeTransfer(vault_, surplusAssets);
        }
    }

    /// @notice Step 8 of the exit: principal never left without shares, and the member vault paid only `amount`
    /// @param vault_ The member vault
    /// @param asset_ The member vault's asset
    /// @param principal_ The principal after the exit
    /// @param expectedIdle_ The member vault's asset balance before the exit minus the amount
    function _checkPostConditions(
        address vault_,
        address asset_,
        uint256 principal_,
        uint256 expectedIdle_
    ) private view {
        if (principal_ > 0 && IERC4626(vault_).balanceOf(address(this)) == 0) {
            revert ReserveVaultSupplyFuseNoShares(vault_, principal_);
        }

        uint256 idleAfter = IERC20(asset_).balanceOf(vault_);

        if (idleAfter != expectedIdle_) {
            revert ReserveVaultSupplyFuseIdleBalanceMismatch(vault_, expectedIdle_, idleAfter);
        }
    }

    /// @notice Liquidity precondition: reverts when the member vault would pull from its markets
    /// @dev Mirrors `PlasmaVault._withdrawFromMarkets` : it returns on a zero target and
    ///      pulls when the target is greater than or equal to the idle balance. A non-zero target therefore needs
    ///      `idle > required`; the target of `withdraw` is never zero.
    /// @param vault_ The member vault
    /// @param idle_ The member vault's balance of its asset
    /// @param required_ The member vault's pull target for the call that follows
    function _checkIdleLiquidity(address vault_, uint256 idle_, uint256 required_) private pure {
        if (required_ != 0 && idle_ <= required_) {
            revert ReserveVaultSupplyFuseInsufficientIdleLiquidity(vault_, idle_, required_);
        }
    }

    /// @notice Refreshes the member vault's boost market
    /// @dev Requires `UPDATE_MARKETS_BALANCES_ROLE` for the reserve vault on the member vault.
    /// @param vault_ The member vault
    function _refreshBoostMarket(address vault_) private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = BOOST_MARKET_ID;
        IPlasmaVault(vault_).updateMarketsBalances(marketIds);
    }
}
