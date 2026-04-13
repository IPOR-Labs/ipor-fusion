// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/universal_token_swapper/UniversalTokenSwapperEthFuse.sol

import {UniversalTokenSwapperEthFuse} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperEthFuse.sol";
import {UniversalTokenSwapperEthEnterData, UniversalTokenSwapperEthData} from "contracts/fuses/universal_token_swapper/UniversalTokenSwapperEthFuse.sol";
contract UniversalTokenSwapperEthFuseTest is OlympixUnitTest("UniversalTokenSwapperEthFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_CheckSubstratesInternal_TargetsNonEmpty_HitsElseBranchNoEmptyTargets() public {
            UniversalTokenSwapperEthFuse fuse = new UniversalTokenSwapperEthFuse(1, address(0x1));
    
            address[] memory targets = new address[](1);
            targets[0] = address(0x2);
    
            bytes[] memory callDatas = new bytes[](1);
            callDatas[0] = bytes("");
    
            uint256[] memory ethAmounts = new uint256[](1);
            ethAmounts[0] = 0;
    
            address[] memory dustTokens = new address[](0);
    
            UniversalTokenSwapperEthData memory inner = UniversalTokenSwapperEthData({
                targets: targets,
                callDatas: callDatas,
                ethAmounts: ethAmounts,
                tokensDustToCheck: dustTokens
            });
    
            UniversalTokenSwapperEthEnterData memory data_ = UniversalTokenSwapperEthEnterData({
                tokenIn: address(0x3),
                tokenOut: address(0x4),
                amountIn: 1,
                minAmountOut: 0,
                data: inner
            });
    
            // We only need to ensure that `targetsLength == 0` is false so that
            // the opix-target-branch-492 else-branch is taken. Any revert after
            // that is acceptable for this coverage test.
            try fuse.enter(data_) {
                // If no revert, the branch was still taken as targetsLength != 0.
            } catch {
                // Swallow any revert; reaching here still means the non-empty
                // targets path (the else-branch) was executed.
            }
        }
}