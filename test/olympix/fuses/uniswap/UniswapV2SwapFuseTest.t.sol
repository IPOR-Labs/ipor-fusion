// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/uniswap/UniswapV2SwapFuse.sol

import {UniswapV2SwapFuse, UniswapV2SwapFuseEnterData} from "contracts/fuses/uniswap/UniswapV2SwapFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {MockToken} from "test/managers/MockToken.sol";
import {IUniversalRouter} from "contracts/fuses/uniswap/ext/IUniversalRouter.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {UniswapV2SwapFuse} from "contracts/fuses/uniswap/UniswapV2SwapFuse.sol";
contract UniswapV2SwapFuseTest is OlympixUnitTest("UniswapV2SwapFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_WhenTokenInAmountZeroOrPathTooShort_DoesNotRevertAndReturnsInputData() public {
            // deploy mock tokens and universal router
            MockToken tokenIn = new MockToken("TokenIn", "TIN");
            MockToken tokenOut = new MockToken("TokenOut", "TOUT");
            IUniversalRouter universalRouter = IUniversalRouter(address(0x1234));
    
            // deploy fuse with arbitrary marketId
            uint256 marketId = 1;
            UniswapV2SwapFuse fuse = new UniswapV2SwapFuse(marketId, address(universalRouter));
    
            // case 1: tokenInAmount == 0, valid path length >= 2
            address[] memory path1 = new address[](2);
            path1[0] = address(tokenIn);
            path1[1] = address(tokenOut);
    
            UniswapV2SwapFuseEnterData memory data1 = UniswapV2SwapFuseEnterData({
                tokenInAmount: 0,
                path: path1,
                minOutAmount: 100
            });
    
            (uint256 retAmount1, address[] memory retPath1, uint256 retMinOut1) = fuse.enter(data1);
            assertEq(retAmount1, data1.tokenInAmount, "tokenInAmount should be echoed back");
            assertEq(retPath1.length, data1.path.length, "path length should be echoed back");
            assertEq(retPath1[0], data1.path[0], "first path element should match");
            assertEq(retPath1[1], data1.path[1], "second path element should match");
            assertEq(retMinOut1, data1.minOutAmount, "minOutAmount should be echoed back");
    
            // case 2: path length < 2, non-zero tokenInAmount
            address[] memory path2 = new address[](1);
            path2[0] = address(tokenIn);
    
            UniswapV2SwapFuseEnterData memory data2 = UniswapV2SwapFuseEnterData({
                tokenInAmount: 100,
                path: path2,
                minOutAmount: 50
            });
    
            (uint256 retAmount2, address[] memory retPath2, uint256 retMinOut2) = fuse.enter(data2);
            assertEq(retAmount2, data2.tokenInAmount, "tokenInAmount should be echoed back for short path");
            assertEq(retPath2.length, data2.path.length, "path length should be echoed back for short path");
            assertEq(retPath2[0], data2.path[0], "path element should match for short path");
            assertEq(retMinOut2, data2.minOutAmount, "minOutAmount should be echoed back for short path");
        }

    function test_enterTransient_ReadsFromAndWritesToTransientStorage() public {
            // set up fuse and supporting mocks
            MockToken tokenIn = new MockToken("TokenIn", "TIN");
            MockToken tokenOut = new MockToken("TokenOut", "TOUT");

            // deploy fuse with dummy marketId and universal router
            uint256 marketId = 1;
            UniswapV2SwapFuse fuse = new UniswapV2SwapFuse(marketId, address(0x1234));
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // prepare transient storage inputs expected by enterTransient
            // layout: [tokenInAmount, pathLength, path[0], path[1], minOutAmount]
            // tokenInAmount = 0 so enter() early-returns before substrate check
            uint256 tokenInAmount = 0;
            uint256 pathLength = 2;
            uint256 minOutAmount = 50;

            bytes32[] memory inputs = new bytes32[](2 + pathLength + 1);
            inputs[0] = TypeConversionLib.toBytes32(tokenInAmount);
            inputs[1] = TypeConversionLib.toBytes32(pathLength);
            inputs[2] = TypeConversionLib.toBytes32(address(tokenIn));
            inputs[3] = TypeConversionLib.toBytes32(address(tokenOut));
            inputs[4] = TypeConversionLib.toBytes32(minOutAmount);

            // write inputs into vault's transient storage
            vault.setInputs(address(fuse), inputs);

            // call enterTransient via vault (delegatecall) so transient storage is shared
            UniswapV2SwapFuse(address(vault)).enterTransient();

            // read outputs from vault's transient storage
            bytes32[] memory outputs = vault.getOutputs(address(fuse));

            // expected layout: [tokenInAmount, pathLength, path[0], path[1], minOutAmount]
            assertEq(outputs.length, inputs.length, "outputs length should match inputs length");
            assertEq(TypeConversionLib.toUint256(outputs[0]), tokenInAmount, "tokenInAmount round-trip");
            assertEq(TypeConversionLib.toUint256(outputs[1]), pathLength, "path length round-trip");
            assertEq(TypeConversionLib.toAddress(outputs[2]), address(tokenIn), "first path element");
            assertEq(TypeConversionLib.toAddress(outputs[3]), address(tokenOut), "second path element");
            assertEq(TypeConversionLib.toUint256(outputs[4]), minOutAmount, "minOutAmount round-trip");
        }
}