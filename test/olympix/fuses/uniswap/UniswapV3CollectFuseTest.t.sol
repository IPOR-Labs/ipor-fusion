// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/uniswap/UniswapV3CollectFuse.sol

import {UniswapV3CollectFuse, UniswapV3CollectFuseEnterData} from "contracts/fuses/uniswap/UniswapV3CollectFuse.sol";
import {INonfungiblePositionManager} from "contracts/fuses/uniswap/ext/INonfungiblePositionManager.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract UniswapV3CollectFuseTest is OlympixUnitTest("UniswapV3CollectFuse") {


    function test_enter_WhenNoTokenIds_ShouldReturnZeroAndNotCallPositionManager() public {
            // Given: deploy fuse with a dummy position manager
            INonfungiblePositionManager positionManager = INonfungiblePositionManager(address(0x1234));
            UniswapV3CollectFuse fuse = new UniswapV3CollectFuse(1, address(positionManager));
    
            uint256[] memory emptyTokenIds = new uint256[](0);
            UniswapV3CollectFuseEnterData memory data_ = UniswapV3CollectFuseEnterData({tokenIds: emptyTokenIds});
    
            // When: calling enter with an empty array
            (uint256 totalAmount0, uint256 totalAmount1) = fuse.enter(data_);
    
            // Then: totals are zero and, importantly, no external call is made,
            // so using a non‑contract address for NONFUNGIBLE_POSITION_MANAGER does not revert
            assertEq(totalAmount0, 0, "totalAmount0 should be zero for empty input");
            assertEq(totalAmount1, 0, "totalAmount1 should be zero for empty input");
        }

    function test_enter_WhenTokenIdsProvided_ShouldEnterElseBranchAndCallPositionManager() public {
            // Given: a mock position manager
            address positionManager = address(0x9999);
            UniswapV3CollectFuse fuse = new UniswapV3CollectFuse(1, positionManager);

            // Mock the collect call to return (0, 0)
            vm.mockCall(
                positionManager,
                abi.encodeWithSelector(INonfungiblePositionManager.collect.selector),
                abi.encode(uint256(0), uint256(0))
            );

            // Prepare a non-empty tokenIds array so the `if (len == 0)` condition is false
            uint256[] memory tokenIds = new uint256[](1);
            tokenIds[0] = 1;
            UniswapV3CollectFuseEnterData memory data_ = UniswapV3CollectFuseEnterData({tokenIds: tokenIds});

            // When: calling enter with a non-empty array
            (uint256 totalAmount0, uint256 totalAmount1) = fuse.enter(data_);

            // Then: execution reaches here without revert
            assertEq(totalAmount0, 0, "totalAmount0 should be zero");
            assertEq(totalAmount1, 0, "totalAmount1 should be zero");
        }

    function test_enterTransient_ShouldReadInputsCallEnterAndSetOutputs() public {
            // Given: deploy fuse with a dummy position manager (no actual external calls will be made
            // because we'll pass an empty tokenIds array through transient storage)
            UniswapV3CollectFuse fuse = new UniswapV3CollectFuse(1, address(0x1234));
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient inputs under the key equal to VERSION (fuse address)
            // inputs[0] = length of tokenIds array (0) -> enter() will early return
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0));

            vault.setInputs(fuse.VERSION(), inputs);

            // When: calling enterTransient via delegatecall through vault
            vault.enterCompoundV2SupplyTransient();

            // Then: outputs are written for the VERSION key and both totals are zero
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length should be 2");
            assertEq(TypeConversionLib.toUint256(outputs[0]), 0, "totalAmount0 should be zero");
            assertEq(TypeConversionLib.toUint256(outputs[1]), 0, "totalAmount1 should be zero");
        }
}