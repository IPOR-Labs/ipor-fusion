// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/uniswap/UniswapV3ModifyPositionFuse.sol

import {UniswapV3ModifyPositionFuse} from "contracts/fuses/uniswap/UniswapV3ModifyPositionFuse.sol";
import {INonfungiblePositionManager} from "contracts/fuses/uniswap/ext/INonfungiblePositionManager.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {MockToken} from "test/managers/MockToken.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract UniswapV3ModifyPositionFuseTest is OlympixUnitTest("UniswapV3ModifyPositionFuse") {


    function test_enterTransient_hitsBranch147True_withUnsupportedTokens() public {
            // Deploy fuse with dummy position manager
            uint256 marketId = 1;
            address dummyPositionManager = address(0x1234);
            UniswapV3ModifyPositionFuse fuse = new UniswapV3ModifyPositionFuse(marketId, dummyPositionManager);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs where token0 and token1 are not granted in PlasmaVaultConfigLib
            // so PlasmaVaultConfigLib.isSubstrateAsAssetGranted(...) returns false
            bytes32[] memory inputs = new bytes32[](8);
            inputs[0] = TypeConversionLib.toBytes32(address(0x1001)); // token0
            inputs[1] = TypeConversionLib.toBytes32(address(0x1002)); // token1
            inputs[2] = TypeConversionLib.toBytes32(uint256(1)); // tokenId
            inputs[3] = TypeConversionLib.toBytes32(uint256(0)); // amount0Desired
            inputs[4] = TypeConversionLib.toBytes32(uint256(0)); // amount1Desired
            inputs[5] = TypeConversionLib.toBytes32(uint256(0)); // amount0Min
            inputs[6] = TypeConversionLib.toBytes32(uint256(0)); // amount1Min
            inputs[7] = TypeConversionLib.toBytes32(block.timestamp + 1); // deadline

            vault.setInputs(fuse.VERSION(), inputs);

            // Calling enterTransient via vault; tokens not granted so enter() reverts
            vm.expectRevert();
            vault.enterCompoundV2SupplyTransient();
        }

    function test_exitTransient_TrueBranchAndOutputs() public {
            // Arrange: deploy fuse with dummy marketId and position manager
            uint256 marketId = 1;
            address dummyNPM = address(0x1234);
            vm.etch(dummyNPM, hex"00");
            UniswapV3ModifyPositionFuse fuse = new UniswapV3ModifyPositionFuse(marketId, dummyNPM);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient storage inputs for VERSION key
            bytes32[] memory inputs = new bytes32[](5);
            uint256 tokenId = 42;
            uint256 liquidity = 1000;
            uint256 amount0Min = 0;
            uint256 amount1Min = 0;
            uint256 deadline = block.timestamp + 1;

            inputs[0] = TypeConversionLib.toBytes32(tokenId);
            inputs[1] = TypeConversionLib.toBytes32(liquidity);
            inputs[2] = TypeConversionLib.toBytes32(amount0Min);
            inputs[3] = TypeConversionLib.toBytes32(amount1Min);
            inputs[4] = TypeConversionLib.toBytes32(deadline);

            vault.setInputs(fuse.VERSION(), inputs);

            // Mock the decreaseLiquidity call
            vm.mockCall(dummyNPM, abi.encodeWithSelector(INonfungiblePositionManager.decreaseLiquidity.selector), abi.encode(uint256(5), uint256(10)));

            // Act: delegatecall exitTransient through vault
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 3, "outputs length");
            assertEq(TypeConversionLib.toUint256(outputs[0]), tokenId, "tokenId output");
        }
}