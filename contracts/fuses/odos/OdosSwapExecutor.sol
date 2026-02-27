// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title OdosSwapExecutor
/// @author IPOR Labs
/// @notice Executor contract for interacting with Odos Router V3
/// @dev This contract receives tokens from OdosSwapperFuse, executes swaps via Odos Router,
///      and returns the resulting tokens back to the caller (PlasmaVault via fuse)
contract OdosSwapExecutor {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the Odos Router swap call fails
    error OdosSwapExecutorSwapFailed();

    /// @notice Odos Router V3 address (same on all EVM chains)
    /// @dev See: https://docs.odos.xyz/build/contracts
    address public constant ODOS_ROUTER = 0x0D05a7D3448512B78fa8A9e46c4872C88C4a0D05;

    /// @notice Executes a swap via Odos Router V3
    /// @dev Approves the router, executes the swap, resets approval, and returns all tokens to caller.
    ///      This function performs the following operations:
    ///      1. Approves Odos Router to spend `amountIn_` of `tokenIn_`
    ///      2. Executes the swap via low-level call using `swapCallData_`
    ///      3. Resets the approval to 0 (security best practice)
    ///      4. Transfers any remaining `tokenIn_` balance back to the caller (PlasmaVault)
    ///      5. Transfers all `tokenOut_` balance to the caller (PlasmaVault)
    ///      Side Effects:
    ///      - Token transfers: All tokens held by this contract after the swap are transferred to msg.sender
    ///      - Approval changes: tokenIn_ approval is set to amountIn_, then reset to 0
    ///      - No return value: This function does not return any value
    /// @custom:security Token approval operations require careful handling. Approval is reset to 0 after swap to prevent unauthorized spending.
    /// @param tokenIn_ The input token address
    /// @param tokenOut_ The output token address
    /// @param amountIn_ The amount of tokenIn to approve for the swap
    /// @param swapCallData_ Raw calldata from Odos API (/sor/assemble response)
    function execute(address tokenIn_, address tokenOut_, uint256 amountIn_, bytes calldata swapCallData_) external {
        // Approve Odos Router to spend tokenIn
        IERC20(tokenIn_).forceApprove(ODOS_ROUTER, amountIn_);

        // Execute swap via low-level call with raw calldata from Odos API
        // slither-disable-next-line low-level-calls
        (bool success, ) = ODOS_ROUTER.call(swapCallData_);
        if (!success) {
            revert OdosSwapExecutorSwapFailed();
        }

        // Reset approval to 0 (security best practice)
        IERC20(tokenIn_).forceApprove(ODOS_ROUTER, 0);

        // Transfer remaining tokenIn back to caller (PlasmaVault)
        uint256 tokenInBalance = IERC20(tokenIn_).balanceOf(address(this));
        if (tokenInBalance > 0) {
            IERC20(tokenIn_).safeTransfer(msg.sender, tokenInBalance);
        }

        // Transfer tokenOut to caller (PlasmaVault)
        uint256 tokenOutBalance = IERC20(tokenOut_).balanceOf(address(this));
        if (tokenOutBalance > 0) {
            IERC20(tokenOut_).safeTransfer(msg.sender, tokenOutBalance);
        }
    }
}
