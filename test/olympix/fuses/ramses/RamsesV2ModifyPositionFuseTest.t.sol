// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/ramses/RamsesV2ModifyPositionFuse.sol

import {RamsesV2ModifyPositionFuse} from "contracts/fuses/ramses/RamsesV2ModifyPositionFuse.sol";
import {INonfungiblePositionManagerRamses} from "contracts/fuses/ramses/ext/INonfungiblePositionManagerRamses.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract RamsesV2ModifyPositionFuseTest is OlympixUnitTest("RamsesV2ModifyPositionFuse") {


    function test_enterTransient_supportedTokens_hitsTrueBranch186() public {
        // Arrange
        uint256 marketId = 0;
        address token0 = address(0x1001);
        address token1 = address(0x1002);
        address npm = address(0x2000);

        vm.etch(token0, hex"00");
        vm.etch(token1, hex"00");
        vm.etch(npm, hex"00");

        RamsesV2ModifyPositionFuse fuse = new RamsesV2ModifyPositionFuse(marketId, npm);
        PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

        // Grant token0 and token1 as substrates via vault
        address[] memory assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
        vault.grantAssetsToMarket(marketId, assets);

        // Prepare inputs for enterTransient
        uint256 tokenIdIn = 1;
        uint256 amount0Desired = 10;
        uint256 amount1Desired = 20;
        uint256 amount0Min = 1;
        uint256 amount1Min = 2;
        uint256 deadline = block.timestamp + 1;

        bytes32[] memory inputs = new bytes32[](8);
        inputs[0] = TypeConversionLib.toBytes32(token0);
        inputs[1] = TypeConversionLib.toBytes32(token1);
        inputs[2] = TypeConversionLib.toBytes32(tokenIdIn);
        inputs[3] = TypeConversionLib.toBytes32(amount0Desired);
        inputs[4] = TypeConversionLib.toBytes32(amount1Desired);
        inputs[5] = TypeConversionLib.toBytes32(amount0Min);
        inputs[6] = TypeConversionLib.toBytes32(amount1Min);
        inputs[7] = TypeConversionLib.toBytes32(deadline);

        vault.setInputs(fuse.VERSION(), inputs);

        // Mock token approvals and increaseLiquidity
        vm.mockCall(token0, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(token1, abi.encodeWithSelector(IERC20.approve.selector), abi.encode(true));
        vm.mockCall(npm, abi.encodeWithSelector(INonfungiblePositionManagerRamses.increaseLiquidity.selector), abi.encode(uint128(100), uint256(10), uint256(20)));

        // Act: delegatecall enterTransient through vault
        vault.enterCompoundV2SupplyTransient();

        // Assert: outputs were written
        bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
        assertEq(outputs.length, 4, "outputs length");
    }

}