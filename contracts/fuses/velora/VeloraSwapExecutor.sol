// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title VeloraSwapExecutor
/// @author IPOR Labs
/// @notice Executor contract for interacting with Velora/ParaSwap Augustus v6.2
/// @dev This contract receives tokens from VeloraSwapperFuse, executes swaps via Augustus v6.2,
///      and returns the resulting tokens back to the caller (PlasmaVault via fuse)
contract VeloraSwapExecutor {
    using SafeERC20 for IERC20;

    /// @notice Error thrown when the Augustus v6.2 swap call fails
    error VeloraSwapExecutorSwapFailed();

    /// @notice Augustus v6.2 address (same on all EVM chains)
    /// @dev See: https://developers.paraswap.network/smart-contracts
    address public constant AUGUSTUS_V6_2 = 0x6A000F20005980200259B80c5102003040001068;

    /// @notice Executes a swap via Velora/ParaSwap Augustus v6.2
    /// @dev Approves the router, executes the swap, resets approval, and returns all tokens to caller.
    ///      This function performs the following operations:
    ///      1. Approves Augustus v6.2 to spend `amountIn_` of `tokenIn_`
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
    /// @param swapCallData_ Raw calldata from Velora/ParaSwap API
    function execute(
        address tokenIn_,
        address tokenOut_,
        uint256 amountIn_,
        bytes calldata swapCallData_
    ) external {
        // Approve Augustus v6.2 to spend tokenIn
        IERC20(tokenIn_).forceApprove(AUGUSTUS_V6_2, amountIn_);

        // Execute swap via low-level call with raw calldata from Velora API
        // slither-disable-next-line low-level-calls
        (bool success, ) = AUGUSTUS_V6_2.call(swapCallData_);
        if (!success) {
            revert VeloraSwapExecutorSwapFailed();
        }

        // Reset approval to 0 (security best practice)
        IERC20(tokenIn_).forceApprove(AUGUSTUS_V6_2, 0);

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
