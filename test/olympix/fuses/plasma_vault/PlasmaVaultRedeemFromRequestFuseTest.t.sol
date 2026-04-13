// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol

import {PlasmaVaultRedeemFromRequestFuse, PlasmaVaultRedeemFromRequestFuseEnterData} from "contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultRedeemFromRequestFuseUnsupportedVault} from "contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol";
import {PlasmaVaultRedeemFromRequestFuse} from "contracts/fuses/plasma_vault/PlasmaVaultRedeemFromRequestFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract PlasmaVaultRedeemFromRequestFuseTest is OlympixUnitTest("PlasmaVaultRedeemFromRequestFuse") {


    function test_enter_WhenSharesZero_HitsZeroSharesBranchAndReturns() public {
            // Arrange: marketId used in the fuse
            uint256 marketId = 1;
            PlasmaVaultRedeemFromRequestFuse fuse = new PlasmaVaultRedeemFromRequestFuse(marketId);
    
            // Create a mock plasma vault token; its address will be used as plasmaVault
            MockERC20 mockVault = new MockERC20("MockPV", "MPV", 18);
    
            // IMPORTANT: Do NOT grant mockVault as a substrate so that the function
            // returns early on the sharesAmount == 0 check and does NOT revert
            PlasmaVaultRedeemFromRequestFuseEnterData memory data_ = PlasmaVaultRedeemFromRequestFuseEnterData({
                sharesAmount: 0,
                plasmaVault: address(mockVault)
            });
    
            // Act
            (address plasmaVaultReturned, uint256 sharesAmountReturned) = fuse.enter(data_);
    
            // Assert: the function should return the input plasmaVault and zero shares
            assertEq(plasmaVaultReturned, address(mockVault), "plasmaVault address mismatch");
            assertEq(sharesAmountReturned, 0, "sharesAmount should be zero");
        }

    function test_enterTransient_HitsTrueBranchAndSetsOutputs() public {
            // Arrange
            uint256 marketId = 1;
            PlasmaVaultRedeemFromRequestFuse fuse = new PlasmaVaultRedeemFromRequestFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Use sharesAmount=0 to trigger early return (no substrate check, no external calls)
            address plasmaVaultIn = address(0xBEEF);

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0));
            inputs[1] = TypeConversionLib.toBytes32(plasmaVaultIn);

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall enterTransient through vault
            vault.enterCompoundV2SupplyTransient();

            // Assert: enter() early-returns with (plasmaVault, 0)
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), plasmaVaultIn, "plasmaVault output mismatch");
            assertEq(TypeConversionLib.toUint256(outputs[1]), 0, "sharesAmount output should be zero");
        }
}