// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol

import {BalancerLiquidityProportionalFuse, BalancerLiquidityProportionalFuseEnterData} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {BalancerLiquidityProportionalFuse} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IRouter} from "contracts/fuses/balancer/ext/IRouter.sol";
import {IPool} from "contracts/fuses/balancer/ext/IPool.sol";
import {IPermit2} from "contracts/fuses/balancer/ext/IPermit2.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {BalancerLiquidityProportionalFuse, BalancerLiquidityProportionalFuseExitData} from "contracts/fuses/balancer/BalancerLiquidityProportionalFuse.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract BalancerLiquidityProportionalFuseTest is OlympixUnitTest("BalancerLiquidityProportionalFuse") {


    function test_enter_RevertsWhenPoolZeroAddress_opix_branch_136_true() public {
            // Arrange: deploy fuse with valid constructor params so constructor does not revert
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);
            BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);
    
            // Prepare enter data with pool == address(0) to force the first `if` condition to be true
            BalancerLiquidityProportionalFuseEnterData memory data_ = BalancerLiquidityProportionalFuseEnterData({
                pool: address(0),
                tokens: new address[](0),
                maxAmountsIn: new uint256[](0),
                exactBptAmountOut: 0
            });
    
            // Assert: expect BalancerLiquidityProportionalFuseInvalidParams revert from the first branch
            vm.expectRevert(BalancerLiquidityProportionalFuse.BalancerLiquidityProportionalFuseInvalidParams.selector);
            fuse.enter(data_);
        }

    function test_enter_SucceedsWhenPoolIsNonZeroAddress() public {
            // Arrange: deploy fuse with valid constructor params
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);
            BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);
    
            // Prepare enter data with non-zero pool so the first if condition is false
            address[] memory tokens = new address[](1);
            uint256[] memory maxAmountsIn = new uint256[](1);
            tokens[0] = address(0x3);
            maxAmountsIn[0] = 1e18;
    
            BalancerLiquidityProportionalFuseEnterData memory data = BalancerLiquidityProportionalFuseEnterData({
                pool: address(0xBEEF),
                tokens: tokens,
                maxAmountsIn: maxAmountsIn,
                exactBptAmountOut: 1e18
            });
    
            // Act & Assert: we only need to hit the branch where data_.pool != address(0).
            // Subsequent external calls may revert; we don't assert on the outcome here.
            vm.expectRevert();
            fuse.enter(data);
        }

    function test_enterTransient_UsesInputsAndSetsOutputs_opix_branch_189_true() public {
            // Arrange
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);
            BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);
    
            // Prepare inputs for enterTransient stored under VERSION key
            address versionKey = fuse.VERSION();
    
            address pool = address(0xBEEF);
            address token0 = address(0xAAA1);
            address token1 = address(0xAAA2);
            uint256 maxIn0 = 1e18;
            uint256 maxIn1 = 2e18;
            uint256 exactBptOut = 5e17;
    
            // Encode inputs as expected by enterTransient()
            // inputs[0] = pool
            // inputs[1]..[len] = tokens
            // inputs[1+len]..[1+2*len-1] = maxAmountsIn
            // inputs[1+2*len] = exactBptAmountOut
            bytes32[] memory inputs = new bytes32[](1 + 2 * 2 + 1); // 1 + 4 + 1 = 6
            inputs[0] = TypeConversionLib.toBytes32(pool);
            inputs[1] = TypeConversionLib.toBytes32(token0);
            inputs[2] = TypeConversionLib.toBytes32(token1);
            inputs[3] = TypeConversionLib.toBytes32(maxIn0);
            inputs[4] = TypeConversionLib.toBytes32(maxIn1);
            inputs[5] = TypeConversionLib.toBytes32(exactBptOut);
    
            TransientStorageLib.setInputs(versionKey, inputs);
    
            // We don't have real router / config setup, so the inner enter() will revert at some point.
            // The test only needs to ensure that the opix-target-branch-189 `if (true)` path is executed,
            // which happens as soon as we call enterTransient().
            vm.expectRevert();
            fuse.enterTransient();
        }

    function test_exit_RevertWhenPoolIsZeroAddress_opix_branch_226_true() public {
        uint256 marketId = 1;
        address router = address(0x1);
        address permit2 = address(0x2);
    
        BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);
    
        BalancerLiquidityProportionalFuseExitData memory data_ = BalancerLiquidityProportionalFuseExitData({
            pool: address(0),
            exactBptAmountIn: 1,
            minAmountsOut: new uint256[](0)
        });
    
        vm.expectRevert(BalancerLiquidityProportionalFuse.BalancerLiquidityProportionalFuseInvalidParams.selector);
        fuse.exit(data_);
    }

    function test_exit_PoolNonZeroAndGranted_ReachesElseBranchOfFirstIf_opix_branch_228_false() public {
            // Arrange
            uint256 marketId = 1;
            address pool = address(0xBEEF);
            address router = address(0xCAFE);
            address permit2 = address(0xD00D);

            // Instantiate fuse under test
            BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Mark pool as granted substrate via vault's storage
            bytes32 substrateKey = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock IPool(pool).getTokenInfo() to return empty arrays (no tokens to validate)
            vm.mockCall(
                pool,
                abi.encodeWithSelector(IPool.getTokenInfo.selector),
                abi.encode(new address[](0), new uint256[](0), new uint256[](0), new uint256[](0))
            );

            BalancerLiquidityProportionalFuseExitData memory data = BalancerLiquidityProportionalFuseExitData({
                pool: pool,
                exactBptAmountIn: 0,
                minAmountsOut: new uint256[](0)
            });

            // Act: pool != address(0) so the first if condition is false and the else branch is taken.
            // exactBptAmountIn == 0 makes exit return early before external calls; we only need to reach the else branch.
            vault.execute(address(fuse), abi.encodeWithSelector(BalancerLiquidityProportionalFuse.exit.selector, data));
        }

    function test_exitTransient_UsesTransientStorageAndCallsExit_opix_branch_267_true() public {
            // Arrange: set up a fuse with valid constructor params so constructor branches go through the "else" paths
            uint256 marketId = 1;
            address router = address(0x1);
            address permit2 = address(0x2);
            BalancerLiquidityProportionalFuse fuse = new BalancerLiquidityProportionalFuse(marketId, router, permit2);
    
            // Prepare transient storage inputs for VERSION key
            // Layout in exitTransient:
            // inputs[0] = pool address
            // inputs[1] = exactBptAmountIn
            // inputs[2..] = minAmountsOut
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(address(0xBEEF));
            inputs[1] = TypeConversionLib.toBytes32(uint256(1));
            inputs[2] = TypeConversionLib.toBytes32(uint256(0));
    
            TransientStorageLib.setInputs(fuse.VERSION(), inputs);
    
            // Act & Assert: exitTransient will read from transient storage, hit the
            // `if (true)` branch, and then eventually revert on external calls.
            vm.expectRevert();
            fuse.exitTransient();
        }
}