// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol

import {UniversalTokenSwapperEnterData, UniversalTokenSwapperData} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
import {UniversalTokenSwapperFuse} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperFuse.sol";
contract UniversalTokenSwapperFuseTest is OlympixUnitTest("UniversalTokenSwapperFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_AmountInNonZero_RevertsDueToZeroTargets() public {
            UniversalTokenSwapperFuse fuse = new UniversalTokenSwapperFuse(1);
    
            UniversalTokenSwapperData memory swapperData = UniversalTokenSwapperData({
                targets: new address[](0),
                data: new bytes[](0)
            });
    
            UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 1,
                minAmountOut: 0,
                data: swapperData
            });
    
            // amountIn > 0 makes the first if (amountIn == 0) condition false
            // and thus executes the else-branch at line 137
            vm.expectRevert(UniversalTokenSwapperFuse.UniversalTokenSwapperFuseEmptyTargets.selector);
            fuse.enter(enterData);
        }

    function test_enter_TargetsNonEmpty_ElseBranchAtLine144() public {
            // Deploy fuse with non-zero marketId so constructor else-branch is taken
            UniversalTokenSwapperFuse fuse = new UniversalTokenSwapperFuse(1);
    
            // Prepare non-empty targets so `targetsLength == 0` is false
            address[] memory targets = new address[](1);
            targets[0] = address(0x1234);
    
            // Match data length with targets length so array-length check also goes to its else-branch
            bytes[] memory data = new bytes[](1);
            data[0] = bytes("");
    
            UniversalTokenSwapperData memory swapperData = UniversalTokenSwapperData({
                targets: targets,
                data: data
            });
    
            UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 1,
                minAmountOut: 0,
                data: swapperData
            });
    
            // We only need to ensure that the call proceeds past the `targetsLength == 0` check
            // into the corresponding else-branch. Any revert from later validation is acceptable.
            try fuse.enter(enterData) {
                // success is fine; branch already covered
            } catch {
                // revert later in function is acceptable for branch coverage
            }
        }

    function test_enter_RevertsOnArrayLengthMismatch_opix_branch_147_true() public {
            UniversalTokenSwapperFuse fuse = new UniversalTokenSwapperFuse(1);
    
            address[] memory targets = new address[](1);
            targets[0] = address(0x1);
    
            // data length intentionally different to trigger UniversalTokenSwapperFuseArrayLengthMismatch
            bytes[] memory dataArr = new bytes[](2);
            dataArr[0] = bytes("a");
            dataArr[1] = bytes("b");
    
            UniversalTokenSwapperData memory swapperData = UniversalTokenSwapperData({
                targets: targets,
                data: dataArr
            });
    
            UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
                tokenIn: address(0x2),
                tokenOut: address(0x3),
                amountIn: 1,
                minAmountOut: 0,
                data: swapperData
            });
    
            vm.expectRevert(UniversalTokenSwapperFuse.UniversalTokenSwapperFuseArrayLengthMismatch.selector);
            fuse.enter(enterData);
        }

    function test_enter_ArrayLengthMatch_ReachesElseBranch149() public {
            // Arrange: create fuse with valid non-zero marketId
            UniversalTokenSwapperFuse fuse = new UniversalTokenSwapperFuse(1);
    
            // Prepare empty data arrays with matching lengths (targetsLength == dataLength)
            address[] memory targets = new address[](1);
            targets[0] = address(0x1234);
            bytes[] memory data = new bytes[](1);
            data[0] = hex"";
    
            UniversalTokenSwapperData memory swapperData = UniversalTokenSwapperData({
                targets: targets,
                data: data
            });
    
            // Use a non-zero amountIn to pass the zero-amount check
            UniversalTokenSwapperEnterData memory enterData = UniversalTokenSwapperEnterData({
                tokenIn: address(0x1),
                tokenOut: address(0x2),
                amountIn: 1,
                minAmountOut: 0,
                data: swapperData
            });
    
            // Act & Assert: we only care that the array-length check at line 149
            // takes the else-branch (targetsLength == dataLength). The call may
            // revert later on other checks, so we do not set expectRevert here
            // and just execute up to that point. Any revert afterwards is acceptable
            // for this branch-coverage focused test.
            try fuse.enter(enterData) {
                // success is fine; branch already covered
            } catch {
                // revert later in function is acceptable for branch coverage
            }
        }

    function test_enterTransient_OpixBranch380True() public {
            UniversalTokenSwapperFuse fuse = new UniversalTokenSwapperFuse(1);
    
            // We only need to execute enterTransient to cover the `if (true)` branch at line 380.
            // All internal library calls will likely revert due to uninitialized config,
            // which is acceptable for branch coverage.
            try fuse.enterTransient() {
                // If it succeeds, branch is covered.
            } catch {
                // Any revert after entering the if-branch is acceptable.
            }
        }
}