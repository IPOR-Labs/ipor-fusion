// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/odos/OdosSwapExecutor.sol

import {OdosSwapExecutor} from "contracts/fuses/odos/OdosSwapExecutor.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
contract OdosSwapExecutorTest is OlympixUnitTest("OdosSwapExecutor") {


    function test_execute_SwapSuccess_EntersElseBranch() public {
            // Arrange
            OdosSwapExecutor executor = new OdosSwapExecutor();
    
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Fund the executor with some tokenIn and tokenOut so transfer paths can execute
            tokenIn.mint(address(executor), 500 ether);
            tokenOut.mint(address(executor), 200 ether);
    
            // Use empty calldata so the low-level call to ODOS_ROUTER is a no-op but still succeeds
            bytes memory swapCallData = hex"";
    
            // Act: this should not revert, so `success` is true and the `else` branch is taken
            executor.execute(address(tokenIn), address(tokenOut), 500 ether, swapCallData);
    
            // Assert basic post-conditions: all tokens are sent back to caller (this test contract)
            assertEq(tokenIn.balanceOf(address(this)), 500 ether, "caller should receive all tokenIn back");
            assertEq(tokenOut.balanceOf(address(this)), 200 ether, "caller should receive all tokenOut");
            assertEq(tokenIn.balanceOf(address(executor)), 0, "executor should hold no tokenIn after execute");
            assertEq(tokenOut.balanceOf(address(executor)), 0, "executor should hold no tokenOut after execute");
        }

    function test_execute_TransfersRemainingTokenInBackToCaller() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);

            // Deploy executor
            OdosSwapExecutor executor = new OdosSwapExecutor();

            // Mint tokenIn to this test contract and then transfer to executor so it has leftover balance
            tokenIn.mint(address(this), 1_000 ether);
            tokenIn.transfer(address(executor), 500 ether);

            // Prepare dummy swap calldata
            bytes memory swapCallData = hex"1234";

            // Mock the ODOS_ROUTER call to revert so execute() hits the failure branch
            vm.mockCallRevert(executor.ODOS_ROUTER(), swapCallData, "swap failed");

            // Expect revert from the low-level call to ODOS_ROUTER
            vm.expectRevert(OdosSwapExecutor.OdosSwapExecutorSwapFailed.selector);
            executor.execute(address(tokenIn), address(tokenOut), 0, swapCallData);

            // Sanity check balances
            assertEq(IERC20(address(tokenIn)).balanceOf(address(executor)), 500 ether, "executor should hold 500 tokenIn");
        }

    function test_execute_EntersElseBranch_NoRemainingTokenIn() public {
        // Arrange
        OdosSwapExecutor executor = new OdosSwapExecutor();

        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);

        // No tokenIn is ever sent to the executor, so its tokenIn balance will be 0
        bytes memory swapCallData = hex"01";

        // Mock the ODOS_ROUTER call to revert
        vm.mockCallRevert(executor.ODOS_ROUTER(), swapCallData, "swap failed");

        vm.expectRevert(OdosSwapExecutor.OdosSwapExecutorSwapFailed.selector);
        executor.execute(address(tokenIn), address(tokenOut), 0, swapCallData);
    }
}