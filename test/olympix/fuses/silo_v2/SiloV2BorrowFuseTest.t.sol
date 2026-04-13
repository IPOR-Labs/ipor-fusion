// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/silo_v2/SiloV2BorrowFuse.sol

import {SiloV2BorrowFuse} from "contracts/fuses/silo_v2/SiloV2BorrowFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ISiloConfig} from "contracts/fuses/silo_v2/ext/ISiloConfig.sol";
import {ISilo} from "contracts/fuses/silo_v2/ext/ISilo.sol";
import {SiloIndex} from "contracts/fuses/silo_v2/SiloIndex.sol";
import {SiloV2BorrowFuse, SiloV2BorrowFuseEnterData} from "contracts/fuses/silo_v2/SiloV2BorrowFuse.sol";
import {SiloV2BorrowFuseExitData} from "contracts/fuses/silo_v2/SiloV2BorrowFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract SiloV2BorrowFuseTest is OlympixUnitTest("SiloV2BorrowFuse") {


    function test_enter_WhenZeroSiloAssetAmount_ReturnsEarlyAndHitsTrueBranch() public {
            // Arrange: create fuse with arbitrary marketId
            uint256 marketId = 1;
            SiloV2BorrowFuse fuse = new SiloV2BorrowFuse(marketId);
    
            // Prepare data with siloAssetAmount == 0 to take the `if (data_.siloAssetAmount == 0)` true branch
            SiloV2BorrowFuseEnterData memory data_ = SiloV2BorrowFuseEnterData({
                siloConfig: address(0x1234),
                siloIndex: SiloIndex.SILO0,
                siloAssetAmount: 0
            });
    
            // Act
            (address siloConfig, address silo, uint256 siloAssetAmountBorrowed, uint256 siloSharesBorrowed) = fuse.enter(data_);
    
            // Assert: early return values
            assertEq(siloConfig, data_.siloConfig, "siloConfig should echo input");
            assertEq(silo, address(0), "silo should be zero address on early return");
            assertEq(siloAssetAmountBorrowed, 0, "borrowed amount should be zero");
            assertEq(siloSharesBorrowed, 0, "borrowed shares should be zero");
        }

    function test_enter_WhenNonZeroSiloAssetAmount_HitsElseBranchAndRevertsOnUnsupportedConfig() public {
            // Arrange
            uint256 marketId = 1;
            SiloV2BorrowFuse fuse = new SiloV2BorrowFuse(marketId);
    
            // Provide a non-zero amount so the first `if (data_.siloAssetAmount == 0)` condition is false
            SiloV2BorrowFuseEnterData memory data_ = SiloV2BorrowFuseEnterData({
                siloConfig: address(0x1234),
                siloIndex: SiloIndex.SILO0,
                siloAssetAmount: 1
            });
    
            // Since PlasmaVaultConfigLib.isSubstrateAsAssetGranted will be false for this config,
            // the call should revert with SiloV2BorrowFuseUnsupportedSiloConfig
            vm.expectRevert();
            fuse.enter(data_);
        }

    function test_exit_zeroAmount_hitsEarlyReturnBranch_opix113True() public {
            uint256 marketId = 1;
            SiloV2BorrowFuse fuse = new SiloV2BorrowFuse(marketId);
    
            SiloV2BorrowFuseExitData memory data_ = SiloV2BorrowFuseExitData({
                siloConfig: address(0x1234),
                siloIndex: SiloIndex.SILO0,
                siloAssetAmount: 0
            });
    
            (address siloConfig, address silo, uint256 siloAssetAmountRepaid, uint256 siloSharesRepaid) = fuse.exit(data_);
    
            assertEq(siloConfig, data_.siloConfig, "siloConfig should be passthrough");
            assertEq(silo, address(0), "silo address should be zero when amount is zero");
            assertEq(siloAssetAmountRepaid, 0, "repaid amount should be zero");
            assertEq(siloSharesRepaid, 0, "repaid shares should be zero");
        }

    function test_enterTransient_UsesInputsAndSetsOutputs_opix144TrueBranch() public {
            // Arrange
            uint256 marketId = 1;
            SiloV2BorrowFuse fuse = new SiloV2BorrowFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs: siloAssetAmount=0 for early return
            address siloConfig = address(0xABC1);
            SiloIndex siloIndex = SiloIndex.SILO0;
            uint256 siloAssetAmount = 0;

            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(siloConfig);
            inputs[1] = TypeConversionLib.toBytes32(uint256(siloIndex));
            inputs[2] = TypeConversionLib.toBytes32(siloAssetAmount);

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall enterTransient through vault
            vault.enterCompoundV2SupplyTransient();

            // Assert: outputs from enter() early return
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 4, "outputs length");

            assertEq(TypeConversionLib.toAddress(outputs[0]), siloConfig, "siloConfig passthrough");
            assertEq(TypeConversionLib.toAddress(outputs[1]), address(0), "silo should be zero for zero amount");
            assertEq(TypeConversionLib.toUint256(outputs[2]), 0, "borrowed amount should be zero");
            assertEq(TypeConversionLib.toUint256(outputs[3]), 0, "borrowed shares should be zero");
        }

    function test_exitTransient_UsesTransientStorageAndHitsTrueBranch_opix168True() public {
            uint256 marketId = 1;
            SiloV2BorrowFuse fuse = new SiloV2BorrowFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs: siloAssetAmount=0 for early return
            address siloConfig = address(0x1234);
            SiloIndex siloIndex = SiloIndex.SILO0;
            uint256 siloAssetAmount = 0;

            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(siloConfig);
            inputs[1] = TypeConversionLib.toBytes32(uint256(siloIndex));
            inputs[2] = TypeConversionLib.toBytes32(siloAssetAmount);

            vault.setInputs(fuse.VERSION(), inputs);

            // Delegatecall exitTransient through vault
            vault.exitCompoundV2SupplyTransient();

            // Verify outputs
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 4, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), siloConfig, "returned siloConfig");
            assertEq(TypeConversionLib.toAddress(outputs[1]), address(0), "silo should be zero address");
            assertEq(TypeConversionLib.toUint256(outputs[2]), 0, "asset amount repaid");
            assertEq(TypeConversionLib.toUint256(outputs[3]), 0, "shares repaid");
        }
}