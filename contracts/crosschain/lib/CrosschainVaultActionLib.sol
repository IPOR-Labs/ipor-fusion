// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReadResult} from "../../universal_reader/UniversalReader.sol";
import {CrosschainConstants} from "./CrosschainConstants.sol";
import {CrosschainErrors} from "./CrosschainErrors.sol";
import {TrackedVaultPricingLib} from "./TrackedVaultPricingLib.sol";

/// @dev Minimal `UniversalReader` surface of a remote PlasmaVault (see `CrosschainVaultActionLib.requireVaultWithdrawManager`).
interface IUniversalReaderLike {
    function read(address target_, bytes memory data_) external view returns (ReadResult memory);
}

/// @title CrosschainVaultActionLib
/// @notice Linked ERC-20 / ERC-4626 helpers shared by both dispatcher runtimes: a scoped approval
///         around `deposit`, reset to zero afterwards, a plain asset transfer, the remote-vault
///         withdraw-manager consistency check, and the gas-bounded best-effort share sweep run when a vault
///         leaves the allowlist (IL-8784), with its optional per-vault floor (IL-9629).
/// @dev This is an external linked library so `SafeERC20` is not duplicated into either dispatcher
///      runtime, which keeps them below EIP-170. It runs through delegatecall, so `address(this)` is
///      the dispatcher: the approval is the dispatcher's, the shares are minted to the dispatcher and
///      transferred tokens leave the dispatcher's balance. Apart from `requireVaultWithdrawManager` and the
///      `DepositMintedNoShares` guard in `depositScoped` (IL-8601) it performs no validation of its own — every
///      other guard around each call stays in the caller.
library CrosschainVaultActionLib {
    using SafeERC20 for IERC20;

    error AddressReadFailed();

    /// @dev Sweep reason codes of `TrackedVaultSweepResidual`; 0 means nothing is left.
    uint8 internal constant SWEEP_NONE = 0;
    /// @dev The dispatcher's share balance of the vault could not be read.
    uint8 internal constant SWEEP_UNREADABLE = 1;
    /// @dev The capped `redeem` call reverted (or ran out of its cap).
    uint8 internal constant SWEEP_REVERTED = 2;
    /// @dev The `redeem` call succeeded but shares are left (e.g. `maxRedeem` below the balance).
    uint8 internal constant SWEEP_PARTIAL = 3;
    /// @dev The held shares are worth at most one hundredth of an asset unit: `redeem` was not called (D-061).
    uint8 internal constant SWEEP_DUST_SKIPPED = 4;
    /// @dev The `redeem` call failed while it was given LESS than `VAULT_SWEEP_GAS` (the command's remaining gas, minus
    ///      the post-call reserve, was the binding limit), or it was skipped for lack of gas. The position may well be
    ///      redeemable with more gas (D-065).
    uint8 internal constant SWEEP_GAS_LIMITED = 5;
    /// @dev IL-9629: a non-zero sweep floor was not reached and nothing was burned: the floored `redeem` received less
    ///      than the floor and was rolled back, or no `redeem` was made (dust or nothing redeemable). IL-9694 D-002:
    ///      also a floored `redeem` that reverted with error data (the vault's own error) and burned nothing. The
    ///      caller keeps the vault TRACKED (off the allowlist, still in NAV) instead of untracking it.
    uint8 internal constant SWEEP_BELOW_MIN = 6;

    /// @notice The best-effort sweep of a vault leaving the allowlist redeemed `sharesRedeemed` shares of `vault`
    ///         and received `assetsLD` (measured, local decimals) (IL-8784).
    event TrackedVaultSwept(address vault, uint256 sharesRedeemed, uint256 assetsLD);

    /// @notice The sweep of `vault` left a residual: `sharesLeft` shares stay on the dispatcher (outside NAV for reasons 1 to 5, see below).
    /// @dev `reason` 1 = share balance unreadable (`sharesLeft` 0), 2 = `redeem` reverted (`redeemError` is the
    ///      first four bytes of its revert data), 3 = partial redeem, 4 = dust skipped (`redeem` never called, D-061;
    ///      `sharesLeft` is the dust balance), 5 = the `redeem` failed (or was skipped) with less than `VAULT_SWEEP_GAS`
    ///      forwarded (gas-limited; also reported for a non-gas revert on a tight lane, so read `redeemError`) (D-065),
    ///      6 = a non-zero sweep floor was not reached and nothing was burned (IL-9629; `redeemError` is the
    ///      `SweepBelowMinimum` selector when the floored `redeem` ran and was rolled back, the vault's own error
    ///      selector when it reverted with error data (IL-9694 D-002), else zero). `untracked` is
    ///      true for reasons 1 to 5: the caller untracks the vault after the sweep whatever is left (D-028), so ALPHA
    ///      must withdraw or recall the position BEFORE removing a vault; such a residual is invisible to NAV until the
    ///      vault is allowlisted again. For reason 6 it is false: the vault stays tracked and in NAV, off the allowlist; the
    ///      shares are outside NAV only for reasons 1 to 5.
    ///      When the share balance cannot be read AFTER the `redeem` call (reasons 2, 3 or 5), `sharesLeft` is the
    ///      balance held BEFORE the sweep: a deliberately cautious over-report that assumes nothing was burned. The
    ///      shares may already be gone, so check the dispatcher's actual balance before scheduling a rescue.
    event TrackedVaultSweepResidual(
        address vault,
        uint256 sharesLeft,
        uint8 reason,
        bytes4 redeemError,
        bool untracked
    );

    /// @notice A non-zero deposit left the dispatcher's share balance of `vault` unchanged (IL-8601).
    error DepositMintedNoShares(address vault, uint256 assets);

    /// @notice The floored sweep `redeem` of `vault` received `receivedLD` of ASSET, below the floor `minAssetsLD`
    ///         (IL-9629). Raised inside the dispatcher's `sweepRedeemSelf` frame and caught by `sweepShares`, which
    ///         reports it as reason 6 (`SWEEP_BELOW_MIN`); it never ends a command.
    error SweepBelowMinimum(address vault, uint256 receivedLD, uint256 minAssetsLD);

    /// @notice Approves `amountLD_` of `asset_` to `vault_`, deposits it, then resets the approval.
    /// @param asset_ The ERC-20 deposited into the vault.
    /// @param vault_ The ERC-4626 vault receiving the deposit.
    /// @param amountLD_ The deposited amount, in local decimals.
    /// @return shares The shares ACTUALLY received: the dispatcher's `vault_` share-balance delta across the call.
    ///         The value `deposit` returns is deliberately ignored — a non-conforming allowlisted vault can
    ///         over-report it (IL-8601), so callers enforce `minShares` against this measured delta.
    /// @dev Reverts `DepositMintedNoShares` when a non-zero deposit leaves the share balance unchanged.
    function depositScoped(address asset_, address vault_, uint256 amountLD_) public returns (uint256 shares) {
        uint256 sharesBefore = IERC20(vault_).balanceOf(address(this));
        IERC20(asset_).forceApprove(vault_, amountLD_);
        IERC4626(vault_).deposit(amountLD_, address(this));
        IERC20(asset_).forceApprove(vault_, 0);
        shares = IERC20(vault_).balanceOf(address(this)) - sharesBefore;
        // Callers already reject a zero amount; the guard keeps this public helper safe on its own.
        if (shares == 0 && amountLD_ != 0) revert DepositMintedNoShares(vault_, amountLD_);
    }

    /// @notice Transfers `amountLD_` of the dispatcher's `ASSET()` to its rescue admin `ADMIN()`.
    /// @dev Both addresses are read back through the dispatcher's own immutable getters rather than passed
    ///      in, which keeps two address arguments off the dispatchers' call sites (EIP-170). The recipient is
    ///      therefore always the immutable `ADMIN()`: if the ASSET issuer blocklists it on this chain, a
    ///      recipient-checking token (e.g. USDC) reverts the transfer and the admin recall has no other exit, while a
    ///      sender-only token (USDT, USDT0) lets it succeed and the tokens are frozen at `ADMIN` (IL-8807).
    /// @param amountLD_ The transferred amount, in local decimals.
    function transferAssetToAdmin(uint256 amountLD_) public {
        IERC20(_readAddress("ASSET()")).safeTransfer(_readAddress("ADMIN()"), amountLD_);
    }

    /// @notice Asserts that `plasmaVault_` is configured with `withdrawManager_`.
    /// @dev Asks the vault itself by running the dispatcher's `plasmaVaultWithdrawManager()` in the vault's storage
    ///      context through `UniversalReader.read`; `address(this)` is the dispatcher (delegatecall). IL-8608: an
    ///      unresolved manager (zero command value or zero read) is never accepted as a match.
    /// @param plasmaVault_ The remote PlasmaVault whose manager is checked.
    /// @param withdrawManager_ The manager named by the command.
    function requireVaultWithdrawManager(address plasmaVault_, address withdrawManager_) public view {
        ReadResult memory result = IUniversalReaderLike(plasmaVault_).read(
            address(this),
            abi.encodeWithSelector(bytes4(keccak256("plasmaVaultWithdrawManager()")))
        );
        address actual = abi.decode(result.data, (address));
        if (withdrawManager_ == address(0) || actual == address(0)) {
            revert CrosschainErrors.WithdrawManagerUnresolved(plasmaVault_);
        }
        if (actual != withdrawManager_) {
            revert CrosschainErrors.WithdrawManagerMismatch(withdrawManager_, plasmaVault_);
        }
    }

    /// @notice Best-effort redemption of the dispatcher's whole position in `vault_` into the dispatcher's `ASSET()`,
    ///         run when the vault leaves the allowlist (IL-8784, D-020), with an optional floor (IL-9629).
    /// @dev IL-9629: with `minAssetsLD_` 0 the sweep is exactly the IL-8784 one below. With a non-zero floor the
    ///      `redeem` runs inside the dispatcher's own `sweepRedeemSelf` frame (same gas cap), which measures the ASSET
    ///      received and reverts `SweepBelowMinimum` below the floor, so a redeem at a manipulated spot price is rolled
    ///      back and the shares stay; dust and a zero redeemable amount make no call. Either way the result is reason 6
    ///      (`SWEEP_BELOW_MIN`, `untracked` false) and the caller keeps the vault tracked. IL-9694 D-002 narrows
    ///      D-028 under a non-zero floor: a `redeem` that reverts WITH error data (the floor's `SweepBelowMinimum` or
    ///      the vault's own error such as `AccountIsLocked`) and burned nothing also reports reason 6, so a
    ///      temporarily locked vault stays tracked and in NAV. A revert without error data (for example the capped
    ///      gas burnt in the `redeem` frame itself, reason 5, D-065; an out-of-gas inside the vault call tree usually
    ///      returns error data, e.g. a PlasmaVault turns an empty fuse revert into `FailedInnerCall`, so it is reason 6
    ///      under a floor and the vault stays tracked, `redeemError` being that selector), a skipped call (too little gas to forward) and an unreadable balance
    ///      (reason 1) still untrack. Error data decides, not `gasLimited`: every sweep on the 3M CCIP lane is
    ///      gas-limited (forwarded gas below `VAULT_SWEEP_GAS`), and a redeem that itself runs out of gas returns no
    ///      data. Without a floor (floor 0, or no entry) D-028 stands: any revert reports reason 2 or 5 and the vault
    ///      is untracked, so a broken vault can still be removed. A vault reverting with any selector can only keep
    ///      its own position tracked; a floor of 0 removes it.
    ///      `address(this)` is the dispatcher (delegatecall). The redeem amount is `min(balanceOf, maxRedeem)`
    ///      (a failed `maxRedeem` read falls back to the balance). The `redeem` is a low-level call capped at
    ///      `min(VAULT_SWEEP_GAS, gasleft() - VAULT_SWEEP_RESERVE_GAS)` that copies at most four bytes of revert data, so a
    ///      gas-burning vault, a returndata bomb or malformed returndata can never break the caller. A vault failing
    ///      (including running out of the forwarded gas) is NEVER a revert here: the residual is reported through the
    ///      event and the return values, and the caller untracks the vault (D-060, D-065). There is deliberately no hard
    ///      gas pre-check: on a CCIP lane a RETRY cannot add gas, so a pre-check above the lane limit would let anyone
    ///      block a removal with a tiny donation. The reserve is per vault: it keeps this vault's post-call reads and
    ///      events (and the command's own bookkeeping) funded; the next vault of the same UPDATE_VAULTS gets whatever is
    ///      left, so the gas a removal batch needs is bounded below by the IL-8625 command budget and a batch of several
    ///      real positions on a tight lane ends with later sweeps limited (reason 5). The no-revert guarantee covers the
    ///      redeem itself and one removal per command: the capped reads that follow a heavy redeem hard-revert with
    ///      `InsufficientGasForVaultRead` below roughly 208k gas, so a later vault of the same UPDATE_VAULTS can make the
    ///      self-call revert and the whole command is NACKed; on tight lanes send one removal per UPDATE_VAULTS and treat
    ///      a NACK as "split the command" (IL-8784, IL-9686).
    ///      Assets are measured as the `ASSET()` balance delta; the vault's reported return value is ignored.
    /// @param vault_ The vault being removed.
    /// @param minAssetsLD_ The sweep floor in the dispatcher's local ASSET decimals; 0 = no floor.
    /// @return redeemed The shares burned (balance before minus balance after).
    /// @return assetsLD The `ASSET()` received, in local decimals.
    /// @return left The shares still held afterwards.
    /// @return reason `SWEEP_NONE`, `SWEEP_UNREADABLE`, `SWEEP_REVERTED`, `SWEEP_PARTIAL`, `SWEEP_DUST_SKIPPED`,
    ///         `SWEEP_GAS_LIMITED` or `SWEEP_BELOW_MIN` (the caller keeps the vault tracked only for the last one).
    /// @return err The first four bytes of the `redeem` revert data (zero when it did not revert or had none).
    function sweepShares(
        address vault_,
        uint256 minAssetsLD_
    ) public returns (uint256 redeemed, uint256 assetsLD, uint256 left, uint8 reason, bytes4 err) {
        (bool ok, uint256 held) = TrackedVaultPricingLib.shares(vault_, address(this));
        if (!ok) {
            emit TrackedVaultSweepResidual(vault_, 0, SWEEP_UNREADABLE, bytes4(0), true);
            return (0, 0, 0, SWEEP_UNREADABLE, bytes4(0));
        }
        if (held == 0) return (0, 0, 0, SWEEP_NONE, bytes4(0));
        if (_isDust(vault_, held)) {
            // IL-9629: under a non-zero floor the skipped dust received nothing, so the floor is not reached.
            reason = minAssetsLD_ == 0 ? SWEEP_DUST_SKIPPED : SWEEP_BELOW_MIN;
            emit TrackedVaultSweepResidual(vault_, held, reason, bytes4(0), minAssetsLD_ == 0);
            return (0, 0, held, reason, bytes4(0));
        }

        uint256 toRedeem = held;
        // `left` holds the `maxRedeem` cap until the post-call balance read (stack depth, IL-9629).
        (ok, left) = _readUint(vault_, abi.encodeCall(IERC4626.maxRedeem, (address(this))));
        if (ok && left < toRedeem) toRedeem = left;

        address asset = _readAddress("ASSET()");
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        bool callOk = true;
        bool gasLimited;
        if (toRedeem != 0) (callOk, err, gasLimited) = _redeemCapped(vault_, toRedeem, minAssetsLD_);
        assetsLD = IERC20(asset).balanceOf(address(this));
        assetsLD = assetsLD > assetBefore ? assetsLD - assetBefore : 0;

        (ok, left) = TrackedVaultPricingLib.shares(vault_, address(this));
        if (!ok) left = held;
        redeemed = left < held ? held - left : 0;
        if (redeemed != 0) emit TrackedVaultSwept(vault_, redeemed, assetsLD);
        if (left != 0) {
            if (minAssetsLD_ != 0 && redeemed == 0 && (toRedeem == 0 || err != bytes4(0))) {
                // IL-9629: the floor was not reached (rolled-back redeem, or nothing redeemable) and nothing burned.
                // IL-9694 D-002: a redeem reverting with the vault's own error (`err` set, e.g. `AccountIsLocked`)
                // counts the same: under a floor the vault stays tracked. No error data (gas burnt) still untracks.
                reason = SWEEP_BELOW_MIN;
            } else {
                reason = callOk ? SWEEP_PARTIAL : (gasLimited ? SWEEP_GAS_LIMITED : SWEEP_REVERTED);
            }
            emit TrackedVaultSweepResidual(vault_, left, reason, err, reason != SWEEP_BELOW_MIN);
        }
    }

    /// @notice The floored redeem of a vault-removal sweep (IL-9629): redeems `shares_` of `vault_` into the
    ///         dispatcher and reverts `SweepBelowMinimum` when the measured `ASSET()` received is below `minAssetsLD_`.
    /// @dev Called only by the dispatcher's own `sweepRedeemSelf`, the self-call frame `sweepShares` opens with the
    ///      sweep gas cap, so the revert rolls the redeem back and the shares stay on the dispatcher. `address(this)` is
    ///      the dispatcher (delegatecall). A failing `redeem` reverts with its own data (copied in full inside the capped
    ///      frame; the caller reads four bytes). The vault's reported return value is ignored, the receipt is measured.
    /// @param vault_ The vault being removed.
    /// @param shares_ The shares to redeem.
    /// @param minAssetsLD_ The floor, in the dispatcher's local ASSET decimals.
    function redeemAtLeast(address vault_, uint256 shares_, uint256 minAssetsLD_) public {
        IERC20 asset = IERC20(_readAddress("ASSET()"));
        uint256 assetBefore = asset.balanceOf(address(this));
        bytes memory data = abi.encodeCall(IERC4626.redeem, (shares_, address(this), address(this)));
        assembly ("memory-safe") {
            if iszero(call(gas(), vault_, 0, add(data, 0x20), mload(data), 0, 0)) {
                let p := mload(0x40)
                returndatacopy(p, 0, returndatasize())
                revert(p, returndatasize())
            }
        }
        uint256 assetAfter = asset.balanceOf(address(this));
        uint256 received = assetAfter > assetBefore ? assetAfter - assetBefore : 0;
        if (received < minAssetsLD_) revert SweepBelowMinimum(vault_, received, minAssetsLD_);
    }

    /// @dev True when `held_` shares are worth at most `10^(decimals - 2)` of the dispatcher's `ASSET()` (one
    ///      hundredth of an asset unit, whatever the asset is worth: 0.01 USDC, 0.01 WETH, 0.01 of an 8-decimal
    ///      BTC-class asset; it equals `ATTESTATION_ZERO_DUST_SD` (10,000 SD units) only with 6 shared decimals,
    ///      always the case on Stargate; with more shared decimals, possible on CCIP, it is larger). Rationale (D-061): a `redeem` of any position, even a
    ///      1-wei donation, otherwise costs up to `VAULT_SWEEP_GAS` plus overhead, which exceeds a 3M CCIP lane
    ///      limit that a RETRY cannot raise, so anyone could block a vault removal for the price of 1 wei.
    ///      Skipping value of at most 0.01 asset unit (about one US cent for USDC, about $30 for a WETH asset, about $1,000 for an 8-decimal BTC-class
    ///      asset at $3k/ETH and $100k/BTC) costs NAV at most that per removed vault, and the residual event
    ///      still reports it. The value is read with two gas-capped views (`decimals()` of the asset and
    ///      `convertToAssets(held_)`); a view that fails, is short or runs out of gas (or an asset with more
    ///      than 36 decimals) counts as NOT dust, so the normal capped redeem path runs. The vault's
    ///      `asset()` is NOT re-checked here (unlike `TrackedVaultPricingLib.price`): a drifted vault is judged in
    ///      foreign units and may be reported as dust (reason 4) while holding real value; the shares are kept, not
    ///      burned, so this only affects monitoring. A vault that
    ///      under-reports `convertToAssets` can only skip the sweep of its own position, which the residual
    ///      event reports; such a vault is allowlisted by governance and can already fail its own redeem.
    function _isDust(address vault_, uint256 held_) private view returns (bool) {
        (bool ok, uint256 dec) = _readUint(_readAddress("ASSET()"), abi.encodeWithSignature("decimals()"));
        if (!ok || dec > 36) return false;
        uint256 bound = dec >= 2 ? 10 ** (dec - 2) : 1;
        uint256 assets;
        (ok, assets) = _readUint(vault_, abi.encodeCall(IERC4626.convertToAssets, (held_)));
        return ok && assets <= bound;
    }

    /// @dev The low-level `redeem(shares, this, this)` with `min(VAULT_SWEEP_GAS, gasleft() - VAULT_SWEEP_RESERVE_GAS)`
    ///      forwarded; copies at most four bytes of revert data. When no more than `VAULT_SWEEP_MIN_GAS` could be
    ///      forwarded the call is skipped (it cannot succeed) and reported as a gas-limited failure. `gasLimited` is true
    ///      whenever the forwarded gas was below `VAULT_SWEEP_GAS`. Since the forwarded gas is at most
    ///      `gasleft() - reserve`, at least the reserve is left afterwards whatever the EIP-150 63/64 rule withholds.
    ///      IL-9629: with a non-zero floor the capped call goes to the dispatcher's own
    ///      `sweepRedeemSelf(vault, shares, floor)` instead (same cap), so a receipt below the floor is rolled back.
    function _redeemCapped(
        address vault_,
        uint256 shares_,
        uint256 minAssetsLD_
    ) private returns (bool callOk, bytes4 err, bool gasLimited) {
        uint256 available = gasleft();
        uint256 reserve = CrosschainConstants.VAULT_SWEEP_RESERVE_GAS;
        uint256 sweepGas = CrosschainConstants.VAULT_SWEEP_GAS;
        uint256 headroom = available > reserve ? available - reserve : 0;
        if (headroom < sweepGas) {
            sweepGas = headroom;
            gasLimited = true;
        }
        if (sweepGas < CrosschainConstants.VAULT_SWEEP_MIN_GAS) return (false, bytes4(0), true);
        address target = vault_;
        bytes memory data;
        if (minAssetsLD_ == 0) {
            data = abi.encodeCall(IERC4626.redeem, (shares_, address(this), address(this)));
        } else {
            target = address(this);
            data = abi.encodeWithSignature("sweepRedeemSelf(address,uint256,uint256)", vault_, shares_, minAssetsLD_);
        }
        assembly ("memory-safe") {
            callOk := call(sweepGas, target, 0, add(data, 0x20), mload(data), 0, 0)
            if and(iszero(callOk), gt(returndatasize(), 3)) {
                let p := mload(0x40)
                returndatacopy(p, 0, 4)
                err := and(mload(p), shl(224, 0xffffffff))
            }
        }
    }

    /// @dev Capped `staticcall` returning the first word; `ok` is false when it failed or returned fewer than 32 bytes.
    function _readUint(address target_, bytes memory data_) private view returns (bool ok, uint256 value) {
        uint256 readGas = TrackedVaultPricingLib.VAULT_READ_GAS;
        if (gasleft() < (readGas * 64) / 63 + 5_000) revert TrackedVaultPricingLib.InsufficientGasForVaultRead();
        assembly ("memory-safe") {
            let out := mload(0x40)
            ok := staticcall(readGas, target_, add(data_, 0x20), mload(data_), out, 0x20)
            ok := and(ok, iszero(lt(returndatasize(), 0x20)))
            if ok {
                value := mload(out)
            }
        }
    }

    function _readAddress(string memory signature_) private view returns (address) {
        (bool ok, bytes memory ret) = address(this).staticcall(abi.encodeWithSignature(signature_));
        if (!ok || ret.length != 32) revert AddressReadFailed();
        return abi.decode(ret, (address));
    }
}
