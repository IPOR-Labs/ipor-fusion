// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol

import {GearboxV3FarmSupplyFuse} from "contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {IFarmingPool} from "contracts/fuses/gearbox_v3/ext/IFarmingPool.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {GearboxV3FarmSupplyFuse, GearboxV3FarmdSupplyFuseEnterData} from "contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {GearboxV3FarmdSupplyFuseExitData} from "contracts/fuses/gearbox_v3/GearboxV3FarmSupplyFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract GearboxV3FarmSupplyFuseTest is OlympixUnitTest("GearboxV3FarmSupplyFuse") {


    function test_enter_WhenDTokenAmountZero_TakesEarlyReturnBranch() public {
            GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(1);
    
            GearboxV3FarmdSupplyFuseEnterData memory data_ = GearboxV3FarmdSupplyFuseEnterData({
                dTokenAmount: 0,
                farmdToken: address(0x1234)
            });
    
            (address farmdToken, address dToken, uint256 amount) = fuse.enter(data_);
    
            assertEq(farmdToken, address(0));
            assertEq(dToken, address(0));
            assertEq(amount, 0);
        }

    function test_enter_WhenDTokenAmountNonZero_TakesElseBranchAndRevertsOnUnsupportedFarmdToken() public {
        GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(1);
    
        GearboxV3FarmdSupplyFuseEnterData memory data_ = GearboxV3FarmdSupplyFuseEnterData({
            dTokenAmount: 1,
            farmdToken: address(0x1234)
        });
    
        vm.expectRevert();
        fuse.enter(data_);
    }

    function test_exit_WhenDTokenAmountZero_TakesEarlyReturnBranch() public {
            GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(1);
    
            GearboxV3FarmdSupplyFuseExitData memory data_ = GearboxV3FarmdSupplyFuseExitData({
                dTokenAmount: 0,
                farmdToken: address(0x1234)
            });
    
            (address farmdToken, uint256 amount) = fuse.exit(data_);
    
            assertEq(farmdToken, address(0));
            assertEq(amount, 0);
        }

    function test_exit_WhenDTokenAmountNonZero_TakesElseBranchAndDoesNotEarlyReturn() public {
            // Arrange: set up fuse and mock storage so that substrate is granted
            uint256 marketId = 1;
            GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(marketId);
    
            // Configure MarketSubstrates so that data_.farmdToken is granted
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
    
            address farmdToken = address(0x1234);
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(farmdToken)] = 1;
    
            // Use dTokenAmount > 0 to force the `if (data_.dTokenAmount == 0)` condition to be false
            GearboxV3FarmdSupplyFuseExitData memory data_ = GearboxV3FarmdSupplyFuseExitData({
                dTokenAmount: 1,
                farmdToken: farmdToken
            });
    
            // We still have no real farming pool at farmdToken so withdraw will revert,
            // but the important thing is that the function does not hit the early return
            // and thus attempts to proceed past the first if-branch.
            vm.expectRevert();
            fuse.exit(data_);
        }

    function test_enterTransient_TakesTrueBranchAndSetsOutputs() public {
            uint256 marketId = 1;
            GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs: dTokenAmount=0 for early return
            bytes32[] memory inputs = new bytes32[](2);
            uint256 dTokenAmount = 0;
            address farmdToken = address(0x1234);

            inputs[0] = TypeConversionLib.toBytes32(dTokenAmount);
            inputs[1] = TypeConversionLib.toBytes32(farmdToken);

            vault.setInputs(fuse.VERSION(), inputs);

            // Call enterTransient via delegatecall through vault
            vault.enterCompoundV2SupplyTransient();

            // Read outputs via vault
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());

            // When enter() early-returns, it returns (address(0), address(0), 0)
            assertEq(outputs.length, 3, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), address(0), "farmdToken output");
            assertEq(TypeConversionLib.toAddress(outputs[1]), address(0), "dToken output");
            assertEq(TypeConversionLib.toUint256(outputs[2]), 0, "amount output");
        }

    function test_exitTransient_TakesTrueBranchAndWritesOutputs() public {
            uint256 marketId = 1;
            GearboxV3FarmSupplyFuse fuse = new GearboxV3FarmSupplyFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient storage: dTokenAmount=0 for early return path
            bytes32[] memory inputs = new bytes32[](2);
            uint256 dTokenAmount = 0;
            address farmdToken = address(0x1234);
            inputs[0] = TypeConversionLib.toBytes32(dTokenAmount);
            inputs[1] = TypeConversionLib.toBytes32(farmdToken);

            vault.setInputs(fuse.VERSION(), inputs);

            // Call exitTransient via delegatecall through vault
            vault.exitCompoundV2SupplyTransient();

            // Verify outputs were written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), address(0), "farmdToken output");
            assertEq(TypeConversionLib.toUint256(outputs[1]), 0, "amount output");
        }
}