// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/euler/EulerV2ControllerFuse.sol

import {EulerV2ControllerFuse, EulerV2ControllerFuseEnterData} from "contracts/fuses/euler/EulerV2ControllerFuse.sol";
import {EulerFuseLib} from "contracts/fuses/euler/EulerFuseLib.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {EulerSubstrate} from "contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {EulerV2ControllerFuseExitData} from "contracts/fuses/euler/EulerV2ControllerFuse.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract EulerV2ControllerFuseTest is OlympixUnitTest("EulerV2ControllerFuse") {


    function test_enter_reverts_whenCannotBorrow_opix_target_branch_53_true() public {
            // Arrange: deploy a minimal IEVC mock (no calls expected because we will revert before using it)
            IEVC evc = IEVC(address(0xdead));
    
            // MARKET_ID can be any value; choose 1
            uint256 marketId = 1;
            EulerV2ControllerFuse fuse = new EulerV2ControllerFuse(marketId, address(evc));
    
            // Configure PlasmaVaultConfigLib storage so that canBorrow(...) returns false
            // We do this by ensuring that for given (marketId, vault, subAccount) there is NO matching EulerSubstrate
            // i.e., we simply leave market substrates empty for this marketId.
            // (No call to PlasmaVaultConfigLib.grantMarketSubstrates, so getMarketSubstrates(marketId) is empty array.)
    
            // Pick arbitrary vault and subAccount that are NOT present in substrates
            address eulerVault = address(0xBEEF);
            bytes1 subAccount = bytes1(uint8(1));
    
            EulerV2ControllerFuseEnterData memory data_ = EulerV2ControllerFuseEnterData({
                eulerVault: eulerVault,
                subAccount: subAccount
            });
    
            // Expect revert with custom error EulerV2ControllerFuseUnsupportedEnterAction(address,bytes1)
            bytes memory expectedRevertData = abi.encodeWithSelector(
                EulerV2ControllerFuse.EulerV2ControllerFuseUnsupportedEnterAction.selector,
                eulerVault,
                subAccount
            );
            vm.expectRevert(expectedRevertData);
    
            // Act: this must hit the `if (!EulerFuseLib.canBorrow(...))` branch and revert
            fuse.enter(data_);
        }

    function test_exitTransient_writesOutputs_opix_target_branch_118_true() public {
            // Arrange
            uint256 marketId = 1;
            address evcAddr = address(0xdead);
            vm.etch(evcAddr, hex"00");
            EulerV2ControllerFuse fuse = new EulerV2ControllerFuse(marketId, evcAddr);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address eulerVault = address(0xBEEF);
            bytes1 subAccount = bytes1(uint8(7));

            // Configure substrates via vault so canSupply returns true during delegatecall
            EulerSubstrate memory substrate = EulerSubstrate({
                eulerVault: eulerVault,
                isCollateral: false,
                canBorrow: false,
                subAccounts: subAccount
            });
            bytes32 encoded = EulerFuseLib.substrateToBytes32(substrate);

            bytes32[] memory substrates = new bytes32[](1);
            substrates[0] = encoded;
            vault.grantMarketSubstrates(marketId, substrates);

            // Mock the EVC.call so exit() doesn't revert on external call
            vm.mockCall(evcAddr, abi.encodeWithSelector(IEVC.call.selector), abi.encode(bytes("")));

            // Prepare transient storage inputs via vault
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(eulerVault);
            inputs[1] = TypeConversionLib.toBytes32(uint256(uint8(subAccount)));
            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall exitTransient through vault
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs stored under VERSION
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), eulerVault, "eulerVault output mismatch");

            // address(this) inside fuse during delegatecall = address(vault)
            address expectedSubAccount = EulerFuseLib.generateSubAccountAddress(address(vault), subAccount);
            assertEq(TypeConversionLib.toAddress(outputs[1]), expectedSubAccount, "subAccount output mismatch");
        }
}