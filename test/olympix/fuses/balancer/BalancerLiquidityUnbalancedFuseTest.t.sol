// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/balancer/BalancerLiquidityUnbalancedFuse.sol

import {BalancerLiquidityUnbalancedFuse} from "contracts/fuses/balancer/BalancerLiquidityUnbalancedFuse.sol";
import {IRouter} from "contracts/fuses/balancer/ext/IRouter.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPermit2} from "contracts/fuses/balancer/ext/IPermit2.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {BalancerLiquidityUnbalancedFuse, BalancerLiquidityUnbalancedFuseEnterData} from "contracts/fuses/balancer/BalancerLiquidityUnbalancedFuse.sol";
import {BalancerLiquidityUnbalancedFuse, BalancerLiquidityUnbalancedFuseExitData} from "contracts/fuses/balancer/BalancerLiquidityUnbalancedFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract BalancerLiquidityUnbalancedFuseTest is OlympixUnitTest("BalancerLiquidityUnbalancedFuse") {


    function test_enter_RevertsWhenPoolZeroAddressAndHitsTrueBranch() public {
        uint256 marketId = 1;
        address router = address(0x1);
        address permit2 = address(0x2);
    
        BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(marketId, router, permit2);
    
        address[] memory tokens = new address[](0);
        uint256[] memory exactAmountsIn = new uint256[](0);
    
        BalancerLiquidityUnbalancedFuseEnterData memory data = BalancerLiquidityUnbalancedFuseEnterData({
            pool: address(0),
            tokens: tokens,
            exactAmountsIn: exactAmountsIn,
            minBptAmountOut: 0
        });
    
        vm.expectRevert(BalancerLiquidityUnbalancedFuse.BalancerLiquidityUnbalancedFuseInvalidParams.selector);
    
        fuse.enter(data);
    }

    function test_enter_AllowsNonZeroPoolAddressAndRevertsOnUnsupportedPool() public {
            // set up a fuse with a valid (non-zero) router & permit2 so constructor passes
            uint256 marketId = 1;
            address router = address(0x1234);
            address permit2 = address(0x5678);
            BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(marketId, router, permit2);
    
            // prepare data so that data_.pool != address(0) and tokens/exactAmountsIn lengths match
            // this makes the first `if (data_.pool == address(0))` condition false,
            // entering its corresponding `else` branch (the opix-target-branch-159 else branch)
            address pool = address(0x9999);
            address[] memory tokens = new address[](1);
            tokens[0] = address(0xAAAA);
    
            uint256[] memory exactAmountsIn = new uint256[](1);
            exactAmountsIn[0] = 1;
    
            BalancerLiquidityUnbalancedFuseEnterData memory data = BalancerLiquidityUnbalancedFuseEnterData({
                pool: pool,
                tokens: tokens,
                exactAmountsIn: exactAmountsIn,
                minBptAmountOut: 0
            });
    
            // We do NOT configure PlasmaVaultConfigLib substrates in this isolated unit test,
            // so the `isMarketSubstrateGranted` check will evaluate to false and the call should
            // revert with BalancerLiquidityUnbalancedFuseUnsupportedPool. This still requires
            // having already passed the `pool == address(0)` check, thus covering the target else branch.
            vm.expectRevert(
                abi.encodeWithSelector(
                    BalancerLiquidityUnbalancedFuse.BalancerLiquidityUnbalancedFuseUnsupportedPool.selector,
                    pool
                )
            );
    
            fuse.enter(data);
        }

    function test_enterTransient_TargetBranch222True_ReadsInputsAndWritesOutputs() public {
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);

            BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(marketId, router, permit2);

            // Use PlasmaVaultMock for delegatecall so transient storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare minimal valid enter() call via transient storage
            address pool = address(0xBEEF);

            // Encode according to enterTransient layout:
            // inputs[0] = pool
            // inputs[1..len] = tokens (addresses) - none
            // inputs[1+len..1+2*len-1] = exactAmountsIn (uint256) - none
            // inputs[1+2*len] = minBptAmountOut
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(pool);
            inputs[1] = TypeConversionLib.toBytes32(uint256(0));

            vault.setInputs(fuse.VERSION(), inputs);

            // Since PlasmaVaultConfigLib.isMarketSubstrateGranted will return false for this isolated test,
            // calling enterTransient will revert with BalancerLiquidityUnbalancedFuseUnsupportedPool
            vm.expectRevert(
                abi.encodeWithSelector(
                    BalancerLiquidityUnbalancedFuse.BalancerLiquidityUnbalancedFuseUnsupportedPool.selector,
                    pool
                )
            );
            vault.execute(address(fuse), abi.encodeWithSignature("enterTransient()"));
        }

    function test_exit_RevertsWhenPoolIsZeroAddress_branch260True() public {
            // Arrange: deploy fuse with dummy non-zero router & permit2 so constructor succeeds
            BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(1, address(0x1), address(0x2));
    
            // Prepare exit data with pool = address(0) so `if (data_.pool == address(0))` is true
            BalancerLiquidityUnbalancedFuseExitData memory data_ = BalancerLiquidityUnbalancedFuseExitData({
                pool: address(0),
                maxBptAmountIn: 1,
                minAmountsOut: new uint256[](0)
            });
    
            // Expect revert with BalancerLiquidityUnbalancedFuseInvalidParams, covering the true branch at line 260
            vm.expectRevert(BalancerLiquidityUnbalancedFuse.BalancerLiquidityUnbalancedFuseInvalidParams.selector);
    
            fuse.exit(data_);
        }

    function test_exit_branch262ElseTaken_poolNonZero() public {
            uint256 marketId = 1;
            address pool = address(0xBEEF);

            // Deploy fuse with non-zero router and permit2 so constructor passes
            BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(marketId, address(0x1), address(0x2));

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant pool as substrate via vault's storage
            bytes32 substrateKey = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock IPool(pool).getTokenInfo() to return empty arrays
            vm.mockCall(pool, abi.encodeWithSelector(bytes4(keccak256("getTokenInfo()"))), abi.encode(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0)));

            // Prepare exit data with non-zero pool so the first if condition is false
            BalancerLiquidityUnbalancedFuseExitData memory data_ = BalancerLiquidityUnbalancedFuseExitData({
                pool: pool,
                maxBptAmountIn: 0,
                minAmountsOut: new uint256[](0)
            });

            // Call exit via vault. This will:
            // - take the else branch of `if (data_.pool == address(0))` (branch 262 else)
            // - then hit the early return path when maxBptAmountIn == 0
            vault.execute(address(fuse), abi.encodeWithSelector(BalancerLiquidityUnbalancedFuse.exit.selector, data_));
        }

    function test_exitTransient_TargetBranch302True_UsesInputsAndSetsOutputs() public {
            // Arrange: deploy fuse with valid dependencies
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);
            BalancerLiquidityUnbalancedFuse fuse = new BalancerLiquidityUnbalancedFuse(marketId, router, permit2);

            // Use PlasmaVaultMock for delegatecall so transient storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant pool as substrate via vault's storage
            address pool = address(0xBEEF);
            bytes32 substrateKey = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock IPool(pool).getTokenInfo() to return empty arrays
            vm.mockCall(pool, abi.encodeWithSelector(bytes4(keccak256("getTokenInfo()"))), abi.encode(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0)));

            // Prepare transient storage inputs
            // Layout: inputs[0] = pool, inputs[1] = maxBptAmountIn, inputs[2..] = minAmountsOut
            uint256 maxBptAmountIn = 0; // forces early-return path in exit()

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(pool);
            inputs[1] = TypeConversionLib.toBytes32(maxBptAmountIn);

            // Write inputs via vault so transient storage is in delegatecall context
            vault.setInputs(fuse.VERSION(), inputs);

            // Act: call exitTransient via vault's delegatecall
            vault.execute(address(fuse), abi.encodeWithSignature("exitTransient()"));

            // Assert: outputs were written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 1, "outputs length should be 1 when no minAmountsOut");
            uint256 bptAmountInOut = TypeConversionLib.toUint256(outputs[0]);
            assertEq(bptAmountInOut, 0, "bptAmountIn should be 0 for maxBptAmountIn == 0");
        }
}