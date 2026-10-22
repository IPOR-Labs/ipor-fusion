// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Mock ERC4626 vault whose `max*` views are a constant 0 (Morpho Vaults V2 behaviour)
/// @dev EIP-4626 lets `maxDeposit/maxMint/maxWithdraw/maxRedeem` under-report. Morpho Vaults V2 returns a constant 0
///      from all of them while `deposit/mint/withdraw/redeem` work, so `deposit/mint/withdraw/redeem` here skip the
///      OpenZeppelin max checks and call the internal `_deposit/_withdraw` with the matching preview, exactly as
///      OpenZeppelin does after its check. The decimals offset is the OpenZeppelin default (0), so the share price is
///      exactly 1:1 until the underlying balance of the vault changes (e.g. a donation).
///      Three switches simulate failures: `previewRedeem` reverting, `convertToAssets` reverting and `withdraw`
///      reverting. An optional exit fee (`setExitFeeBps`, 0 by default) makes `previewRedeem` net of the fee and
///      `previewWithdraw` grossed up, like `MockERC4626WithFee`, while `convertToAssets` stays fee-free.
contract MockERC4626ZeroMax is ERC4626 {
    using Math for uint256;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Thrown by `previewRedeem` when `setPreviewRedeemReverts(true)` was called
    error MockERC4626ZeroMaxPreviewRedeemReverted();

    /// @notice Thrown by `convertToAssets` when `setConvertToAssetsReverts(true)` was called
    error MockERC4626ZeroMaxConvertToAssetsReverted();

    /// @notice Thrown by `withdraw` and `redeem` when `setWithdrawReverts(true)` was called
    error MockERC4626ZeroMaxWithdrawReverted();

    /// @notice Thrown by `setExitFeeBps` when the fee is not below 100%
    error MockERC4626ZeroMaxInvalidExitFeeBps(uint256 exitFeeBps);

    /// @notice When true, `previewRedeem` reverts with `MockERC4626ZeroMaxPreviewRedeemReverted`
    bool public previewRedeemReverts;

    /// @notice When true, `convertToAssets` reverts with `MockERC4626ZeroMaxConvertToAssetsReverted`
    bool public convertToAssetsReverts;

    /// @notice When true, `withdraw` reverts with `MockERC4626ZeroMaxWithdrawReverted`
    bool public withdrawReverts;

    /// @notice Exit fee in basis points (1 bp = 0.01%), 0 by default. Kept by the vault, not paid to the receiver.
    uint256 public exitFeeBps;

    /// @notice Number of `withdraw` calls that were not reverted (a reverted call rolls its increment back)
    uint256 public withdrawCalls;

    constructor(IERC20 asset_, string memory name_, string memory symbol_) ERC4626(asset_) ERC20(name_, symbol_) {}

    function setPreviewRedeemReverts(bool previewRedeemReverts_) external {
        previewRedeemReverts = previewRedeemReverts_;
    }

    function setConvertToAssetsReverts(bool convertToAssetsReverts_) external {
        convertToAssetsReverts = convertToAssetsReverts_;
    }

    function setWithdrawReverts(bool withdrawReverts_) external {
        withdrawReverts = withdrawReverts_;
    }

    /// @param exitFeeBps_ Exit fee in basis points, must be below 10_000
    function setExitFeeBps(uint256 exitFeeBps_) external {
        if (exitFeeBps_ >= BPS_DENOMINATOR) {
            revert MockERC4626ZeroMaxInvalidExitFeeBps(exitFeeBps_);
        }
        exitFeeBps = exitFeeBps_;
    }

    /// @dev Constant 0, like Morpho Vaults V2
    function maxDeposit(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Constant 0, like Morpho Vaults V2
    function maxMint(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Constant 0, like Morpho Vaults V2
    function maxWithdraw(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Constant 0, like Morpho Vaults V2
    function maxRedeem(address) public pure override returns (uint256) {
        return 0;
    }

    /// @dev Net of the exit fee. Reverts when `setPreviewRedeemReverts(true)` was called.
    function previewRedeem(uint256 shares_) public view override returns (uint256) {
        if (previewRedeemReverts) {
            revert MockERC4626ZeroMaxPreviewRedeemReverted();
        }
        return _redeemableAssets(shares_);
    }

    /// @dev Grossed up by the exit fee: the shares to burn also cover the fee that stays in the vault.
    ///      Identical to the OpenZeppelin implementation while the exit fee is 0.
    function previewWithdraw(uint256 assets_) public view override returns (uint256) {
        uint256 fee = assets_.mulDiv(exitFeeBps, BPS_DENOMINATOR - exitFeeBps, Math.Rounding.Ceil);
        return _convertToShares(assets_ + fee, Math.Rounding.Ceil);
    }

    /// @dev Fee-free, so it differs from `previewRedeem` while the exit fee is above 0.
    ///      Reverts when `setConvertToAssetsReverts(true)` was called.
    function convertToAssets(uint256 shares_) public view override returns (uint256) {
        if (convertToAssetsReverts) {
            revert MockERC4626ZeroMaxConvertToAssetsReverted();
        }
        return super.convertToAssets(shares_);
    }

    /// @dev Works although `maxDeposit` is 0: no max check
    function deposit(uint256 assets_, address receiver_) public override returns (uint256 shares) {
        shares = previewDeposit(assets_);
        _deposit(_msgSender(), receiver_, assets_, shares);
    }

    /// @dev Works although `maxMint` is 0: no max check
    function mint(uint256 shares_, address receiver_) public override returns (uint256 assets) {
        assets = previewMint(shares_);
        _deposit(_msgSender(), receiver_, assets, shares_);
    }

    /// @dev Works although `maxWithdraw` is 0: no max check
    function withdraw(uint256 assets_, address receiver_, address owner_) public override returns (uint256 shares) {
        if (withdrawReverts) {
            revert MockERC4626ZeroMaxWithdrawReverted();
        }
        ++withdrawCalls;
        shares = previewWithdraw(assets_);
        _withdraw(_msgSender(), receiver_, owner_, assets_, shares);
    }

    /// @dev Works although `maxRedeem` is 0: no max check. Uses the fee-adjusted conversion, not the switchable
    ///      `previewRedeem`, so `setPreviewRedeemReverts` only affects the view.
    function redeem(uint256 shares_, address receiver_, address owner_) public override returns (uint256 assets) {
        if (withdrawReverts) {
            revert MockERC4626ZeroMaxWithdrawReverted();
        }
        assets = _redeemableAssets(shares_);
        _withdraw(_msgSender(), receiver_, owner_, assets, shares_);
    }

    /// @dev Assets paid for `shares_` net of the exit fee (rounded down in favour of the vault)
    function _redeemableAssets(uint256 shares_) private view returns (uint256) {
        return
            _convertToAssets(shares_, Math.Rounding.Floor).mulDiv(
                BPS_DENOMINATOR - exitFeeBps,
                BPS_DENOMINATOR,
                Math.Rounding.Floor
            );
    }
}
