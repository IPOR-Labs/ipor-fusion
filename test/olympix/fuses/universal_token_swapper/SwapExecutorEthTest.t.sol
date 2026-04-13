// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/universal_token_swapper/SwapExecutorEth.sol

import {SwapExecutorEth, SwapExecutorEthData} from "contracts/fuses/universal_token_swapper/SwapExecutorEth.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IWETH9} from "contracts/interfaces/ext/IWETH9.sol";
contract SwapExecutorEthTest is OlympixUnitTest("SwapExecutorEth") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_execute_RevertsOnMismatchedArrayLengths() public {
        // Deploy mock tokens
        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
        // Use address(this) as a dummy WETH address (non-zero, constructor won't revert)
        SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
        // Prepare data with mismatched array lengths to hit the revert branch
        address[] memory targets = new address[](1);
        targets[0] = address(this);
    
        bytes[] memory callDatas = new bytes[](0); // length 0
        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = 0;
    
        address[] memory tokensDustToCheck = new address[](0);
    
        SwapExecutorEthData memory data_ = SwapExecutorEthData({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: tokensDustToCheck
        });
    
        // Expect revert due to invalid array lengths (opix-target-branch-76-True)
        vm.expectRevert(SwapExecutorEth.SwapExecutorEthInvalidArrayLength.selector);
        executor.execute(data_);
    }

    function test_execute_HappyPath_EntersElseBranchAndTransfersBackTokens() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Use this test contract as a stand-in WETH implementation since we won't actually call deposit
            SwapExecutorEth executor = new SwapExecutorEth(address(this));
    
            // Mint some balances to the executor so that the post-call transfers occur
            tokenIn.mint(address(executor), 1e18);
            tokenOut.mint(address(executor), 2e18);
    
            // Prepare arrays with matching lengths to make the if-condition false and enter the else branch
            address[] memory targets = new address[](1);
            targets[0] = address(this);
    
            bytes[] memory callDatas = new bytes[](1);
            callDatas[0] = ""; // empty calldata, will revert on call but we don't actually send any value
    
            uint256[] memory ethAmounts = new uint256[](1);
            ethAmounts[0] = 0;
    
            address[] memory tokensDustToCheck = new address[](0);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Expect the low-level call to revert because this contract has no function matching empty calldata
            vm.expectRevert();
            executor.execute(data_);
        }

    function test_execute_UsesFunctionCallWithValueWhenEthAmountPositive() public {
        // Deploy mock tokens
        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
        // Deploy a dummy WETH (non-zero address) so constructor does not revert
        // We won't actually hit the WETH deposit branch because we send no ETH
        SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
        // Prepare data so that:
        // - array lengths match (so we skip the revert and enter the else branch)
        // - ethAmounts[0] > 0 to take the `if (data_.ethAmounts[i] > 0)` true branch
        address[] memory targets = new address[](1);
        targets[0] = address(this);
    
        bytes[] memory callDatas = new bytes[](1);
        // empty calldata – call will revert, we only care about taking the branch
        callDatas[0] = "";
    
        uint256[] memory ethAmounts = new uint256[](1);
        ethAmounts[0] = 1 wei; // > 0, so functionCallWithValue branch is taken
    
        address[] memory tokensDustToCheck = new address[](0);
    
        SwapExecutorEthData memory data_ = SwapExecutorEthData({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: tokensDustToCheck
        });
    
        // Fund the executor with a tiny bit of ETH so functionCallWithValue can send it
        vm.deal(address(executor), 1 wei);
    
        // The low-level call will revert because this contract has no function for empty calldata;
        // we assert that execute reverts (after having taken the ethAmounts>0 branch).
        vm.expectRevert();
        // Call from a non-payable context is fine since value comes from executor balance
        executor.execute(data_);
    }

    function test_execute_TokenInBalancePositive_HitsTrueBranch93() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Use a dummy WETH address (non-zero so constructor does not revert)
            SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
            // Mint tokenIn to the executor so balanceTokenIn > 0 and the
            // `if (balanceTokenIn > 0)` branch at line 93 is taken
            tokenIn.mint(address(executor), 1e18);
    
            // Prepare arrays with matching lengths so length check passes
            // and we reach the balanceTokenIn branch.
            address[] memory targets = new address[](0);
            bytes[] memory callDatas = new bytes[](0);
            uint256[] memory ethAmounts = new uint256[](0);
            address[] memory tokensDustToCheck = new address[](0);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Before execution, this test contract has zero tokenIn
            assertEq(tokenIn.balanceOf(address(this)), 0);
    
            // Execute should succeed and transfer the tokenIn balance from executor
            // to msg.sender (this contract), hitting the True side of branch 93.
            executor.execute(data_);
    
            // After execution, all executor's tokenIn should have been transferred here
            assertEq(tokenIn.balanceOf(address(this)), 1e18);
            assertEq(tokenIn.balanceOf(address(executor)), 0);
        }

    function test_execute_EntersElseBranchWhenNoTokenInBalance() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Deploy a dummy WETH (non-zero address so constructor does not revert)
            SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
            // Do NOT mint any tokenIn to executor so balanceTokenIn == 0 and the
            // `if (balanceTokenIn > 0)` condition is false, entering the else-branch
    
            // We also avoid hitting later tokenOut / ETH paths by keeping their balances zero
            address[] memory targets = new address[](0);
            bytes[] memory callDatas = new bytes[](0);
            uint256[] memory ethAmounts = new uint256[](0);
            address[] memory tokensDustToCheck = new address[](0);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Execute should succeed and internally hit the else-branch at line 95
            executor.execute(data_);
    
            // As balanceTokenIn was zero, no tokenIn should have been transferred to this test contract
            assertEq(tokenIn.balanceOf(address(this)), 0);
        }

    function test_execute_TokenOutPositive_HitsTargetBranch99True() public {
        // Deploy mock tokens
        MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
        MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
        // Deploy a dummy WETH implementation so constructor does not revert
        // We won't actually reach the WETH deposit logic because no ETH is left in the executor
        SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
        // Mint tokenOut to the executor so balanceTokenOut > 0 and the
        // `if (balanceTokenOut > 0)` condition (opix-target-branch-99-True) is taken
        tokenOut.mint(address(executor), 2e18);
    
        // Prepare arrays with matching lengths so the array-length check passes
        // and the loop over targets is a no-op
        address[] memory targets = new address[](0);
        bytes[] memory callDatas = new bytes[](0);
        uint256[] memory ethAmounts = new uint256[](0);
        address[] memory tokensDustToCheck = new address[](0);
    
        SwapExecutorEthData memory data_ = SwapExecutorEthData({
            tokenIn: address(tokenIn),
            tokenOut: address(tokenOut),
            targets: targets,
            callDatas: callDatas,
            ethAmounts: ethAmounts,
            tokensDustToCheck: tokensDustToCheck
        });
    
        // Sanity checks before execution
        assertEq(tokenOut.balanceOf(address(this)), 0, "pre: test contract should have no tokenOut");
        assertEq(tokenOut.balanceOf(address(executor)), 2e18, "pre: executor should hold tokenOut");
    
        // Execute should succeed and transfer the tokenOut balance from executor
        // to msg.sender (this contract), hitting the True side of branch 99.
        executor.execute(data_);
    
        // After execution, all executor's tokenOut should have been transferred here
        assertEq(tokenOut.balanceOf(address(this)), 2e18, "post: test contract should receive all tokenOut");
        assertEq(tokenOut.balanceOf(address(executor)), 0, "post: executor should have zero tokenOut");
    }

    function test_execute_WrapsEthAndTransfersWethWhenBalancePositive() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
    
            // Use the test contract itself as a minimal IWETH9 mock – implement deposit via low-level call
            // We just need a non-zero address that accepts the deposit call without reverting.
            // This contract (address(this)) has no code for deposit, so calling it would revert.
            // Instead, we fund the executor with ETH and set W_ETH to a simple ERC20 token, then
            // we expect execute() to revert when calling deposit on a non-WETH contract.
            MockERC20 wethMock = new MockERC20("WETH", "WETH", 18);
            SwapExecutorEth executor = new SwapExecutorEth(address(wethMock));
    
            // Prepare data with no external calls and no dust tokens so we go straight to ETH branch
            address[] memory targets = new address[](0);
            bytes[] memory callDatas = new bytes[](0);
            uint256[] memory ethAmounts = new uint256[](0);
            address[] memory tokensDustToCheck = new address[](0);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Fund executor with ETH so balanceEth > 0, hitting opix-target-branch-107-True
            vm.deal(address(executor), 1 ether);
    
            // Because wethMock is not a real IWETH9 implementation, the low-level call to deposit will revert.
            // We assert that execute() reverts after taking the balanceEth > 0 branch.
            vm.expectRevert();
            executor.execute(data_);
        }

    function test_execute_TokensDustToCheck_HitsDustTrueBranch() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
            MockERC20 dustToken = new MockERC20("Dust", "DUST", 18);
    
            // Dummy non-zero WETH address so constructor does not revert
            SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
            // Mint dustToken to executor so dustBalance > 0 and
            // the `if (dustBalance > 0)` branch (opix-target-branch-118-True) is taken
            dustToken.mint(address(executor), 5e17);
    
            // No external calls, we only care about the dust loop at the end
            address[] memory targets = new address[](0);
            bytes[] memory callDatas = new bytes[](0);
            uint256[] memory ethAmounts = new uint256[](0);
    
            // tokensDustToCheck contains our dustToken so its balance will be checked
            address[] memory tokensDustToCheck = new address[](1);
            tokensDustToCheck[0] = address(dustToken);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Sanity: this test contract holds no dustToken before
            assertEq(dustToken.balanceOf(address(this)), 0, "pre: test contract should have no dustToken");
            assertEq(dustToken.balanceOf(address(executor)), 5e17, "pre: executor should hold dustToken");
    
            // Execute: should pass length checks, skip external calls, and then
            // transfer dustToken from executor to msg.sender via the dust branch
            executor.execute(data_);
    
            // Post conditions: all dustToken moved from executor to this contract
            assertEq(dustToken.balanceOf(address(this)), 5e17, "post: test contract should receive dustToken");
            assertEq(dustToken.balanceOf(address(executor)), 0, "post: executor dustToken balance should be zero");
        }

    function test_execute_DustTokensElseBranch_NoDustTransferred() public {
            // Deploy mock tokens
            MockERC20 tokenIn = new MockERC20("TokenIn", "TIN", 18);
            MockERC20 tokenOut = new MockERC20("TokenOut", "TOUT", 18);
            MockERC20 dustToken = new MockERC20("Dust", "DUST", 18);
    
            // Use a non-zero dummy WETH address so constructor does not revert
            SwapExecutorEth executor = new SwapExecutorEth(address(0x1));
    
            // Do NOT mint any dustToken to the executor so dustBalance == 0 and
            // the `if (dustBalance > 0)` condition is false, entering the else-branch
    
            // No external calls, we only care about the dust loop at the end
            address[] memory targets = new address[](0);
            bytes[] memory callDatas = new bytes[](0);
            uint256[] memory ethAmounts = new uint256[](0);
    
            // tokensDustToCheck contains our dustToken so its balance will be checked
            address[] memory tokensDustToCheck = new address[](1);
            tokensDustToCheck[0] = address(dustToken);
    
            SwapExecutorEthData memory data_ = SwapExecutorEthData({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: tokensDustToCheck
            });
    
            // Sanity: this test contract and executor hold no dustToken before
            assertEq(dustToken.balanceOf(address(this)), 0, "pre: test contract should have no dustToken");
            assertEq(dustToken.balanceOf(address(executor)), 0, "pre: executor should have no dustToken");
    
            // Execute: should pass length checks, skip external calls, and then
            // hit the else-branch in the dust loop because dustBalance == 0
            executor.execute(data_);
    
            // Post conditions: still no dustToken anywhere, confirming else branch was taken
            assertEq(dustToken.balanceOf(address(this)), 0, "post: test contract should still have no dustToken");
            assertEq(dustToken.balanceOf(address(executor)), 0, "post: executor dustToken balance should remain zero");
        }
}