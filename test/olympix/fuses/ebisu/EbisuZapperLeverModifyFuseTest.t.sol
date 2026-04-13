// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol

import {EbisuZapperLeverModifyFuse} from "contracts/fuses/ebisu/EbisuZapperLeverModifyFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {FuseStorageLib} from "contracts/libraries/FuseStorageLib.sol";
import {EbisuZapperSubstrateLib, EbisuZapperSubstrate, EbisuZapperSubstrateType} from "contracts/fuses/ebisu/lib/EbisuZapperSubstrateLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ILeverageZapper} from "contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract EbisuZapperLeverModifyFuseTest is OlympixUnitTest("EbisuZapperLeverModifyFuse") {


    function test_enterTransient_UsesInputsAndStoresOutputs() public {
            // Deploy fuse with arbitrary MARKET_ID
            uint256 marketId = 1;
            EbisuZapperLeverModifyFuse fuse = new EbisuZapperLeverModifyFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare inputs for enterTransient stored under VERSION address
            address zapper = address(0x1234);
            uint256 flashLoanAmount = 1000;
            uint256 ebusdAmount = 500;
            uint256 maxUpfrontFee = 10;

            bytes32[] memory inputs = new bytes32[](4);
            inputs[0] = bytes32(uint256(uint160(zapper)));
            inputs[1] = bytes32(flashLoanAmount);
            inputs[2] = bytes32(ebusdAmount);
            inputs[3] = bytes32(maxUpfrontFee);

            vault.setInputs(fuse.VERSION(), inputs);

            // Grant zapper as a valid substrate in PlasmaVaultConfigLib via vault
            EbisuZapperSubstrate memory substrate = EbisuZapperSubstrate({
                substrateType: EbisuZapperSubstrateType.ZAPPER,
                substrateAddress: zapper
            });
            bytes32 substrateKey = EbisuZapperSubstrateLib.substrateToBytes32(substrate);
            vault.grantMarketSubstrates(marketId, _toSingleElementArray(substrateKey));

            // Set troveId for zapper in FuseStorageLib via vault.execute delegatecall
            uint256 troveId = 42;
            vault.execute(
                address(this),
                abi.encodeWithSelector(this.setTroveId.selector, zapper, troveId)
            );

            // We don't want the external call to revert, so mock the zapper leverUpTrove
            vm.etch(zapper, hex"00");
            vm.mockCall(zapper, abi.encodeWithSelector(ILeverageZapper.leverUpTrove.selector), abi.encode());

            // Act: call enterTransient via delegatecall through vault
            vault.enterCompoundV2SupplyTransient();

            // Assert: outputs stored under VERSION address
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(address(uint160(uint256(outputs[0]))), zapper, "zapper output");
            assertEq(uint256(outputs[1]), troveId, "troveId output");
        }
    
        // Helper to create single-element bytes32[] in-line without separate function in test file
        function _toSingleElementArray(bytes32 value) internal pure returns (bytes32[] memory arr) {
            arr = new bytes32[](1);
            arr[0] = value;
        }

        // Helper that can be delegatecalled by PlasmaVaultMock to set troveId in FuseStorageLib
        function setTroveId(address zapper, uint256 troveId) external {
            FuseStorageLib.getEbisuTroveIds().troveIds[zapper] = troveId;
        }

    function test_exitTransient_branchTrueAndWritesOutputs() public {
            // setUp: deploy fuse with arbitrary marketId
            EbisuZapperLeverModifyFuse fuse = new EbisuZapperLeverModifyFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // configure storage for granted zapper substrate so exit() doesn't revert
            address zapper = address(0xBEEF);
            EbisuZapperSubstrate memory substrate = EbisuZapperSubstrate({
                substrateType: EbisuZapperSubstrateType.ZAPPER,
                substrateAddress: zapper
            });
            bytes32 substrateKey = EbisuZapperSubstrateLib.substrateToBytes32(substrate);
            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = substrateKey;
            vault.grantMarketSubstrates(1, substrates);

            // set troveId in FuseStorageLib via delegatecall
            uint256 expectedTroveId = 42;
            vault.execute(
                address(this),
                abi.encodeWithSelector(this.setTroveId.selector, zapper, expectedTroveId)
            );

            // set inputs in transient storage under VERSION key via vault
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(zapper);
            inputs[1] = TypeConversionLib.toBytes32(uint256(100)); // flashLoanAmount
            inputs[2] = TypeConversionLib.toBytes32(uint256(50));  // minBoldAmount
            vault.setInputs(fuse.VERSION(), inputs);

            // mock the external zapper leverDownTrove call
            vm.etch(zapper, hex"00");
            vm.mockCall(zapper, abi.encodeWithSelector(ILeverageZapper.leverDownTrove.selector), abi.encode());

            // warp to non-zero timestamp for realism (not strictly required)
            vm.warp(1);

            // act: call exitTransient via delegatecall through vault
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs were written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), zapper, "zapper output must match");
            assertEq(TypeConversionLib.toUint256(outputs[1]), expectedTroveId, "troveId output must match");
        }
}