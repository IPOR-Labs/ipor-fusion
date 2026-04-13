// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/universal_token_swapper/SwapExecutorRestricted.sol

import {SwapExecutorRestricted, SwapExecutorData} from "contracts/fuses/universal_token_swapper/SwapExecutorRestricted.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
contract SwapExecutorRestrictedTest is OlympixUnitTest("SwapExecutorRestricted") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_execute_TokenInEqualsTokenOut_SendsFullBalanceBack() public {
            // Deploy a mock ERC20 token
            MockERC20 token = new MockERC20("Mock", "MCK", 18);
    
            // Mint tokens to this test contract (which will also be the RESTRICTED caller)
            token.mint(address(this), 1_000 ether);
    
            // Deploy SwapExecutorRestricted with this test contract as the RESTRICTED address
            SwapExecutorRestricted executor = new SwapExecutorRestricted(address(this));
    
            // Transfer some tokens to the executor so it has a balance to send back
            token.transfer(address(executor), 500 ether);
    
            // Prepare SwapExecutorData with tokenIn == tokenOut and no DEX calls
            address[] memory dexs = new address[](0);
            bytes[] memory dexsData = new bytes[](0);
    
            SwapExecutorData memory data_ = SwapExecutorData({
                tokenIn: address(token),
                tokenOut: address(token),
                dexs: dexs,
                dexsData: dexsData
            });
    
            // Record balances before execution
            uint256 executorBalanceBefore = token.balanceOf(address(executor));
            uint256 callerBalanceBefore = token.balanceOf(address(this));
    
            // When: execute is called by the RESTRICTED address and tokenIn == tokenOut
            executor.execute(data_);
    
            // Then: the executor should send its entire token balance back to the caller
            uint256 executorBalanceAfter = token.balanceOf(address(executor));
            uint256 callerBalanceAfter = token.balanceOf(address(this));
    
            assertEq(executorBalanceBefore, 500 ether, "executorBalanceBefore");
            assertEq(executorBalanceAfter, 0, "executorBalanceAfter should be zero");
            assertEq(
                callerBalanceAfter,
                callerBalanceBefore + executorBalanceBefore,
                "caller should receive full executor balance when tokenIn == tokenOut"
            );
        }

    function test_execute_TokenInEqualsTokenOut_NoBalance_ElseBranch() public {
        // given: mock token and executor with this test as RESTRICTED
        MockERC20 token = new MockERC20("Mock", "MCK", 18);
        token.mint(address(this), 1_000 ether);
        SwapExecutorRestricted executor = new SwapExecutorRestricted(address(this));
    
        // Ensure executor has zero balance of the token so the `if (balance > 0)` is false
        assertEq(token.balanceOf(address(executor)), 0, "executor should start with zero balance");
    
        // Prepare SwapExecutorData with tokenIn == tokenOut and no DEX calls
        address[] memory dexs = new address[](0);
        bytes[] memory dexsData = new bytes[](0);
    
        SwapExecutorData memory data_ = SwapExecutorData({
            tokenIn: address(token),
            tokenOut: address(token),
            dexs: dexs,
            dexsData: dexsData
        });
    
        uint256 callerBalanceBefore = token.balanceOf(address(this));
    
        // when: execute is called and tokenIn == tokenOut but executor holds no tokens
        executor.execute(data_);
    
        // then: balances remain unchanged and `if (balance > 0)` branch is not taken
        assertEq(token.balanceOf(address(executor)), 0, "executor balance should remain zero");
        assertEq(token.balanceOf(address(this)), callerBalanceBefore, "caller balance should be unchanged");
    }

    function test_execute_TokenInNotEqualTokenOut_ZeroTokenInBalance_ElseBranch() public {
            // given: two mock tokens and executor with this test as RESTRICTED
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Mint some tokens to this contract so we can distinguish balances, but
            // DO NOT send any tokenIn to the executor so its tokenIn balance stays 0
            tokenIn.mint(address(this), 1_000 ether);
            tokenOut.mint(address(this), 1_000 ether);
    
            SwapExecutorRestricted executor = new SwapExecutorRestricted(address(this));
    
            // Sanity check: executor has zero balance of tokenIn and tokenOut
            assertEq(tokenIn.balanceOf(address(executor)), 0, "executor tokenIn balance must be zero");
            assertEq(tokenOut.balanceOf(address(executor)), 0, "executor tokenOut balance must be zero");
    
            // Prepare SwapExecutorData with tokenIn != tokenOut and no DEX calls
            address[] memory dexs = new address[](0);
            bytes[] memory dexsData = new bytes[](0);
    
            SwapExecutorData memory data_ = SwapExecutorData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                dexs: dexs,
                dexsData: dexsData
            });
    
            uint256 callerTokenInBefore = tokenIn.balanceOf(address(this));
            uint256 callerTokenOutBefore = tokenOut.balanceOf(address(this));
    
            // when: execute is called and tokenIn != tokenOut but executor holds no tokens
            executor.execute(data_);
    
            // then: the `if (balanceTokenIn > 0)` branch is NOT taken, we hit the else-assert branch
            // and balances remain unchanged
            assertEq(tokenIn.balanceOf(address(executor)), 0, "executor tokenIn balance should remain zero");
            assertEq(tokenOut.balanceOf(address(executor)), 0, "executor tokenOut balance should remain zero");
            assertEq(tokenIn.balanceOf(address(this)), callerTokenInBefore, "caller tokenIn balance should be unchanged");
            assertEq(tokenOut.balanceOf(address(this)), callerTokenOutBefore, "caller tokenOut balance should be unchanged");
        }

    function test_execute_TokenInNotEqualTokenOut_SendsTokenOutBack_BranchTrue() public {
        // given: two mock tokens and executor with this test as RESTRICTED
        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
        // Mint tokens to this contract
        tokenIn.mint(address(this), 1_000 ether);
        tokenOut.mint(address(this), 1_000 ether);
    
        // Deploy executor restricted to this test contract
        SwapExecutorRestricted executor = new SwapExecutorRestricted(address(this));
    
        // Transfer some tokenOut to the executor so balanceTokenOut > 0 and the True branch is taken
        tokenOut.transfer(address(executor), 500 ether);
    
        // Sanity: executor has zero tokenIn but positive tokenOut balance
        assertEq(tokenIn.balanceOf(address(executor)), 0, "executor tokenIn balance must be zero");
        assertEq(tokenOut.balanceOf(address(executor)), 500 ether, "executor tokenOut balance must be 500");
    
        // Prepare SwapExecutorData with tokenIn != tokenOut and no DEX calls
        address[] memory dexs = new address[](0);
        bytes[] memory dexsData = new bytes[](0);
    
        SwapExecutorData memory data_ = SwapExecutorData({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            dexs: dexs,
            dexsData: dexsData
        });
    
        uint256 callerTokenOutBefore = tokenOut.balanceOf(address(this));
    
        // when: execute is called and balanceTokenOut > 0, the opix-target-branch-156-True branch must be taken
        executor.execute(data_);
    
        // then: executor sends its entire tokenOut balance back to caller via the True branch
        assertEq(tokenOut.balanceOf(address(executor)), 0, "executor tokenOut balance should be zero after execute");
        assertEq(
            tokenOut.balanceOf(address(this)),
            callerTokenOutBefore + 500 ether,
            "caller should receive full executor tokenOut balance"
        );
    }
}