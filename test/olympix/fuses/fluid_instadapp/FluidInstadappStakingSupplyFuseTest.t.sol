// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/fluid_instadapp/FluidInstadappStakingSupplyFuse.sol

import {FluidInstadappStakingSupplyFuse} from "contracts/fuses/fluid_instadapp/FluidInstadappStakingSupplyFuse.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {IFluidLendingStakingRewards} from "contracts/fuses/fluid_instadapp/ext/IFluidLendingStakingRewards.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
contract FluidInstadappStakingSupplyFuseTest is OlympixUnitTest("FluidInstadappStakingSupplyFuse") {


    function test_instantWithdraw_ZeroAmount_DoesNothing() public {
            // Arrange: deploy fuse with arbitrary marketId
            FluidInstadappStakingSupplyFuse fuse = new FluidInstadappStakingSupplyFuse(1);
    
            // Prepare params: amount == 0 to hit opix-target-branch-118-True
            bytes32[] memory params = new bytes32[](2);
            params[0] = TypeConversionLib.toBytes32(uint256(0)); // amount = 0
            params[1] = TypeConversionLib.toBytes32(address(0x1234)); // dummy stakingPool, should be unused when amount=0
    
            // Act & Assert: function should simply return without reverting
            fuse.instantWithdraw(params);
        }

    function test_enterTransient_UsesTransientStorageAndHitsBranch179True() public {
            // Arrange: deploy fuse with some marketId
            FluidInstadappStakingSupplyFuse fuse = new FluidInstadappStakingSupplyFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address stakingPool = address(0xBEEF);
            vm.etch(stakingPool, hex"00");
            address stakingToken = address(0xAAAA);
            vm.etch(stakingToken, hex"00");

            // Grant stakingPool as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = stakingPool;
            vault.grantAssetsToMarket(1, assets);

            // Mock stakingToken() and balanceOf() calls
            vm.mockCall(stakingPool, abi.encodeWithSelector(IFluidLendingStakingRewards.stakingToken.selector), abi.encode(stakingToken));
            vm.mockCall(stakingToken, abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)), abi.encode(uint256(0)));

            // Prepare inputs: fluidTokenAmount=123 to enter the function
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(123));
            inputs[1] = TypeConversionLib.toBytes32(stakingPool);

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall enterTransient through vault
            vault.enterCompoundV2SupplyTransient();

            // Assert: outputs written (deposit=0 because balance is 0)
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 3, "enterTransient should write 3 outputs");
        }

    function test_exitTransient_UsesTransientStorageAndHitsBranch198True() public {
            // Arrange: deploy fuse with arbitrary marketId
            FluidInstadappStakingSupplyFuse fuse = new FluidInstadappStakingSupplyFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address stakingPool = address(0x1234);
            vm.etch(stakingPool, hex"00");

            // Grant stakingPool as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = stakingPool;
            vault.grantAssetsToMarket(1, assets);

            // Mock balanceOf to return 0 so _exit early-returns
            vm.mockCall(stakingPool, abi.encodeWithSelector(IFluidLendingStakingRewards.balanceOf.selector, address(vault)), abi.encode(uint256(0)));

            // Prepare inputs in transient storage via vault
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(123));
            inputs[1] = TypeConversionLib.toBytes32(stakingPool);

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall exitTransient through vault
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "exitTransient should write two outputs");
        }
}