// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorphoFlashLoanCallback} from "@morpho-org/morpho-blue/src/interfaces/IMorphoCallbacks.sol";

/// @title MockMorphoFlashLender
/// @notice Test-only stand-in for Morpho Blue `flashLoan` (IL-9404 regression coverage): sends the tokens to the
///         caller, calls `onMorphoFlashLoan` on it and pulls the same amount back, like Morpho Blue does.
/// @dev Optionally transfers a configured amount of the loan token from its own reserve to a target (for example an
///      ERC-4626 market of the vault) after the callback returned and before the repayment is pulled. This simulates
///      a change of a market's value that happens after the callback, so tests can check which value the vault caches.
contract MockMorphoFlashLender {
    using SafeERC20 for IERC20;

    /// @notice Thrown when a flash loan of zero assets is requested (Morpho Blue reverts with ZERO_ASSETS)
    error MockMorphoFlashLenderZeroAssets();

    /// @notice Receiver of the transfer made after the callback (address(0) = no transfer)
    address public afterCallbackTransferTarget;

    /// @notice Amount of the loan token transferred to the target after the callback
    uint256 public afterCallbackTransferAmount;

    /// @notice Configures a transfer of the loan token to `target_` after every callback (`amount_` = 0 disables it)
    /// @param target_ Receiver of the transfer
    /// @param amount_ Amount transferred from the lender's own reserve
    function setAfterCallbackTransfer(address target_, uint256 amount_) external {
        afterCallbackTransferTarget = target_;
        afterCallbackTransferAmount = amount_;
    }

    /// @notice Flash loan with Morpho Blue semantics: transfer, callback, pull of the repayment
    /// @param token_ Token lent
    /// @param assets_ Amount lent
    /// @param data_ Data passed to the callback
    function flashLoan(address token_, uint256 assets_, bytes calldata data_) external {
        if (assets_ == 0) {
            revert MockMorphoFlashLenderZeroAssets();
        }

        IERC20(token_).safeTransfer(msg.sender, assets_);

        IMorphoFlashLoanCallback(msg.sender).onMorphoFlashLoan(assets_, data_);

        if (afterCallbackTransferAmount != 0) {
            IERC20(token_).safeTransfer(afterCallbackTransferTarget, afterCallbackTransferAmount);
        }

        IERC20(token_).safeTransferFrom(msg.sender, address(this), assets_);
    }
}
