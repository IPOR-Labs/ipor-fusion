// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

/// @title PlasmaVaultSlippageRouter
/// @notice Stateless peripheral router adding ERC-5143-style slippage protection (`minShares` / `maxAssets`)
///         to deposits and mints on any existing PlasmaVault (IL-9681).
/// @dev The vault applies the deposit fee and the share price at execution time, so a fee increase (or a price move)
///      between signing and inclusion silently reduces the shares received. The router pulls the assets from the
///      caller, calls the vault with the caller's chosen `receiver`, and reverts with `SlippageExceeded` when the
///      outcome is worse than the caller's bound. It holds no funds between transactions and leaves no allowance.
///
///      Access control: the vault sees the router as `msg.sender`. For vaults with a restricted deposit
///      (whitelist), the router must itself be granted the role that allows `deposit` / `mint` on the vault, and
///      therefore it additionally checks that the original caller is allowed to call the same selector on the
///      vault, so that a non-whitelisted user cannot bypass the whitelist through the router. The redemption lock
///      is started by the vault for `receiver`, exactly as for a direct call.
///
///      The router is not compatible with fee-on-transfer underlying assets.
contract PlasmaVaultSlippageRouter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Shares received are lower than `minShares`, or assets spent are higher than `maxAssets`.
    /// @param actual Shares minted (deposit) or assets spent (mint)
    /// @param limit The bound given by the caller (`minShares` or `maxAssets`)
    error SlippageExceeded(uint256 actual, uint256 limit);

    /// @notice The caller is not allowed to call the vault's `deposit` / `mint` selector directly.
    /// @param caller The router caller
    /// @param vault The target vault
    error CallerNotAllowed(address caller, address vault);

    /// @notice Zero vault address
    error ZeroVault();

    /// @notice Deposits `assets_` into `vault_` and reverts when fewer than `minShares_` shares are minted.
    /// @param vault_ The vault (ERC-4626)
    /// @param assets_ Amount of underlying assets pulled from the caller (needs allowance for this router)
    /// @param receiver_ Receiver of the shares
    /// @param minShares_ Minimum shares accepted
    /// @return shares Shares minted to `receiver_`
    function deposit(
        address vault_,
        uint256 assets_,
        address receiver_,
        uint256 minShares_
    ) external nonReentrant returns (uint256 shares) {
        IERC20 asset = _prepare(vault_, IERC4626.deposit.selector);

        asset.safeTransferFrom(msg.sender, address(this), assets_);
        asset.forceApprove(vault_, assets_);

        shares = IERC4626(vault_).deposit(assets_, receiver_);

        asset.forceApprove(vault_, 0);

        if (shares < minShares_) {
            revert SlippageExceeded(shares, minShares_);
        }
    }

    /// @notice Mints exactly `shares_` of `vault_` and reverts when more than `maxAssets_` assets would be spent.
    /// @param vault_ The vault (ERC-4626)
    /// @param shares_ Shares to mint to `receiver_`
    /// @param receiver_ Receiver of the shares
    /// @param maxAssets_ Maximum assets accepted; this amount is pulled and the unspent part is returned
    /// @return assets Assets spent
    function mint(
        address vault_,
        uint256 shares_,
        address receiver_,
        uint256 maxAssets_
    ) external nonReentrant returns (uint256 assets) {
        IERC20 asset = _prepare(vault_, IERC4626.mint.selector);

        asset.safeTransferFrom(msg.sender, address(this), maxAssets_);
        asset.forceApprove(vault_, maxAssets_);

        assets = IERC4626(vault_).mint(shares_, receiver_);

        asset.forceApprove(vault_, 0);

        if (assets > maxAssets_) {
            revert SlippageExceeded(assets, maxAssets_);
        }

        uint256 unspent = maxAssets_ - assets;
        if (unspent > 0) {
            asset.safeTransfer(msg.sender, unspent);
        }
    }

    function _prepare(address vault_, bytes4 selector_) private view returns (IERC20) {
        if (vault_ == address(0)) {
            revert ZeroVault();
        }
        (bool immediate, ) = IAccessManager(IAccessManaged(vault_).authority()).canCall(msg.sender, vault_, selector_);
        if (!immediate) {
            revert CallerNotAllowed(msg.sender, vault_);
        }
        return IERC20(IERC4626(vault_).asset());
    }
}
