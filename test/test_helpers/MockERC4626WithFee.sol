// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title Mock ERC4626 vault with a configurable withdrawal fee
/// @dev The fee is applied in basis points (1 bp = 0.01%). This creates a discrepancy
/// between `convertToAssets(balanceOf(owner))` and `maxWithdraw(owner)`, which is the
/// exact scenario that triggers the ERC4626ExceededMaxWithdraw revert in the old code.
contract MockERC4626WithFee is ERC4626 {
    using Math for uint256;

    uint256 public immutable WITHDRAWAL_FEE_BPS;
    uint256 private constant BPS_DENOMINATOR = 10_000;

    constructor(
        IERC20 asset_,
        string memory name_,
        string memory symbol_,
        uint256 withdrawalFeeBps_
    ) ERC4626(asset_) ERC20(name_, symbol_) {
        WITHDRAWAL_FEE_BPS = withdrawalFeeBps_;
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 0;
    }

    /// @dev Override maxWithdraw to account for withdrawal fee.
    /// The fee-adjusted max withdraw is less than convertToAssets(balanceOf(owner)).
    function maxWithdraw(address owner) public view override returns (uint256) {
        uint256 assetsFromShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        return assetsFromShares.mulDiv(BPS_DENOMINATOR - WITHDRAWAL_FEE_BPS, BPS_DENOMINATOR, Math.Rounding.Floor);
    }

    /// @dev Override previewWithdraw to include fee in the share calculation.
    /// For a given `assets` amount, the user must burn more shares to cover the fee.
    /// The extra burned shares stay as unclaimable value in the vault (benefiting remaining holders).
    function previewWithdraw(uint256 assets) public view override returns (uint256) {
        uint256 fee = assets.mulDiv(WITHDRAWAL_FEE_BPS, BPS_DENOMINATOR - WITHDRAWAL_FEE_BPS, Math.Rounding.Ceil);
        return _convertToShares(assets + fee, Math.Rounding.Ceil);
    }
}
