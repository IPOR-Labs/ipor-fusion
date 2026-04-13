// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/balancer/BalancerSingleTokenFuse.sol

import {BalancerSingleTokenFuse, BalancerSingleTokenFuseEnterData} from "contracts/fuses/balancer/BalancerSingleTokenFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalancerSingleTokenFuse, BalancerSingleTokenFuseExitData} from "contracts/fuses/balancer/BalancerSingleTokenFuse.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "contracts/fuses/balancer/BalancerSubstrateLib.sol";
import {IRouter} from "contracts/fuses/balancer/ext/IRouter.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract BalancerSingleTokenFuseTest is OlympixUnitTest("BalancerSingleTokenFuse") {


    function test_enter_RevertsOnInvalidParams_branch153True() public {
            // Prepare a BalancerSingleTokenFuse instance with a non-zero router to satisfy constructor
            BalancerSingleTokenFuse fuse = new BalancerSingleTokenFuse({
                marketId_: 1,
                balancerRouter_: address(0x1),
                permit2_: address(0x2)
            });
    
            // Construct data with an invalid pool address (zero) so that:
            // if (data_.pool == address(0) || data_.tokenIn == address(0)) { // opix-target-branch-153-True
            //     revert BalancerSingleTokenFuseInvalidParams();
            // }
            BalancerSingleTokenFuseEnterData memory data_ = BalancerSingleTokenFuseEnterData({
                pool: address(0),
                tokenIn: address(0x1234),
                maxAmountIn: 1,
                exactBptAmountOut: 1
            });
    
            vm.expectRevert(BalancerSingleTokenFuse.BalancerSingleTokenFuseInvalidParams.selector);
            fuse.enter(data_);
        }

    function test_enter_SucceedsAndHitsBranch155Else() public {
            uint256 marketId = 1;
            address pool = address(0xBEEF);

            // Deploy fuse with valid non-zero router and permit2 to satisfy constructor
            BalancerSingleTokenFuse fuse = new BalancerSingleTokenFuse({
                marketId_: marketId,
                balancerRouter_: address(0x1),
                permit2_: address(0x2)
            });

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant pool as POOL substrate via vault's storage
            bytes32 substrateKey = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(marketId, substrates);

            // Prepare data with non-zero pool and tokenIn so the first if condition is false
            BalancerSingleTokenFuseEnterData memory data_ = BalancerSingleTokenFuseEnterData({
                pool: pool,
                tokenIn: address(0x1234),
                maxAmountIn: 0,
                exactBptAmountOut: 1
            });

            // Call via vault. Should take early return 0 path after passing branch 155 else
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(BalancerSingleTokenFuse.enter.selector, data_)
            );
            assertTrue(success, "enter should not revert");
            uint256 amountIn = abi.decode(result, (uint256));
            assertEq(amountIn, 0, "Expected amountIn to be zero when maxAmountIn is zero");
        }

    function test_exit_RevertsOnInvalidParams_branch223True() public {
            // Create a BalancerSingleTokenFuse instance with valid constructor params
            BalancerSingleTokenFuse fuse = new BalancerSingleTokenFuse({
                marketId_: 1,
                balancerRouter_: address(0x1),
                permit2_: address(0x2)
            });
    
            // Construct data with zero pool and non-zero tokenOut to trigger
            // if (data_.pool == address(0) || data_.tokenOut == address(0)) { // opix-target-branch-223-True
            BalancerSingleTokenFuseExitData memory data_ = BalancerSingleTokenFuseExitData({
                pool: address(0),
                tokenOut: address(0x1),
                maxBptAmountIn: 1,
                exactAmountOut: 1
            });
    
            vm.expectRevert(BalancerSingleTokenFuse.BalancerSingleTokenFuseInvalidParams.selector);
            fuse.exit(data_);
        }

    function test_exit_ValidParams_EnterElseBranch() public {
            uint256 marketId = 1;
            address pool = address(0x1001);
            address tokenOut = address(0x2002);

            // deploy fuse with non-zero router & permit2 so constructor does not revert
            address router = address(0x3003);
            address permit2 = address(0x4004);
            BalancerSingleTokenFuse fuse = new BalancerSingleTokenFuse(marketId, router, permit2);

            // Use PlasmaVaultMock for delegatecall so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant BOTH pool and tokenOut substrates in a single call (grantMarketSubstrates revokes first)
            bytes32 poolSubstrate = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32 tokenSubstrate = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.TOKEN, substrateAddress: tokenOut})
            );
            bytes32[] memory substrates = new bytes32[](2);
            substrates[0] = poolSubstrate;
            substrates[1] = tokenSubstrate;
            vault.grantMarketSubstrates(marketId, substrates);

            // create a minimal exit data struct
            BalancerSingleTokenFuseExitData memory data = BalancerSingleTokenFuseExitData({
                pool: pool,
                tokenOut: tokenOut,
                maxBptAmountIn: 0,
                exactAmountOut: 0
            });

            // Call via vault
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(BalancerSingleTokenFuse.exit.selector, data)
            );
            assertTrue(success, "exit should not revert");
            uint256 bptAmountIn = abi.decode(result, (uint256));
            assertEq(bptAmountIn, 0, "Expected bptAmountIn to be 0 when maxBptAmountIn is 0");
        }

    function test_exitTransient_branch264True_andWritesOutputs() public {
            uint256 marketId = 1;
            address pool = address(0x1001);
            address tokenOut = address(0x2002);

            // Deploy fuse with non-zero router & permit2
            BalancerSingleTokenFuse fuse = new BalancerSingleTokenFuse({
                marketId_: marketId,
                balancerRouter_: address(0x3003),
                permit2_: address(0x4004)
            });

            // Use PlasmaVaultMock for delegatecall so transient + regular storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant BOTH pool and tokenOut substrates in a single call
            bytes32 poolSubstrate = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.POOL, substrateAddress: pool})
            );
            bytes32 tokenSubstrate = BalancerSubstrateLib.substrateToBytes32(
                BalancerSubstrate({substrateType: BalancerSubstrateType.TOKEN, substrateAddress: tokenOut})
            );
            bytes32[] memory substrates = new bytes32[](2);
            substrates[0] = poolSubstrate;
            substrates[1] = tokenSubstrate;
            vault.grantMarketSubstrates(marketId, substrates);

            // Prepare transient inputs for VERSION key
            bytes32[] memory inputs = new bytes32[](4);
            inputs[0] = TypeConversionLib.toBytes32(pool);
            inputs[1] = TypeConversionLib.toBytes32(tokenOut);
            inputs[2] = TypeConversionLib.toBytes32(uint256(0)); // maxBptAmountIn = 0 triggers early return 0 in exit()
            inputs[3] = TypeConversionLib.toBytes32(uint256(0)); // exactAmountOut

            vault.setInputs(fuse.VERSION(), inputs);

            // Call exitTransient via vault's delegatecall
            vault.execute(address(fuse), abi.encodeWithSignature("exitTransient()"));

            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 1, "Expected exactly one output value");
            assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "Expected bptAmountIn to be 0");
        }
}