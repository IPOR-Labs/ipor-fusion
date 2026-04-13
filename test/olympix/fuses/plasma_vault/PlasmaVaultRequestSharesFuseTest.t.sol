// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/plasma_vault/PlasmaVaultRequestSharesFuse.sol

import {PlasmaVaultRequestSharesFuse, PlasmaVaultRequestSharesFuseEnterData} from "contracts/fuses/plasma_vault/PlasmaVaultRequestSharesFuse.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {WithdrawManager} from "contracts/managers/withdraw/WithdrawManager.sol";
import {UniversalReader} from "contracts/universal_reader/UniversalReader.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract PlasmaVaultRequestSharesFuseTest is OlympixUnitTest("PlasmaVaultRequestSharesFuse") {


    function test_enter_zeroSharesAmount_hitsEarlyReturnBranch() public {
            // given
            uint256 marketId = 1;
            address plasmaVault = address(0x1234);
    
            // we only want to hit the early return branch `if (data_.sharesAmount == 0)`
            // so we don't need to configure substrates, balances or withdraw manager
    
            PlasmaVaultRequestSharesFuse fuse = new PlasmaVaultRequestSharesFuse(marketId);
    
            PlasmaVaultRequestSharesFuseEnterData memory data_ = PlasmaVaultRequestSharesFuseEnterData({
                sharesAmount: 0,
                plasmaVault: plasmaVault
            });
    
            // when
            (address returnedPlasmaVault, uint256 returnedSharesAmount) = fuse.enter(data_);
    
            // then - branch `if (data_.sharesAmount == 0)` is taken and function returns immediately
            assertEq(returnedPlasmaVault, plasmaVault, "plasmaVault should match input");
            assertEq(returnedSharesAmount, 0, "sharesAmount should be zero on early return");
        }

    function test_enter_nonZeroSharesAmount_hitsElseBranch() public {
            // given
            uint256 marketId = 1;
            address plasmaVault = address(0x1234);

            PlasmaVaultRequestSharesFuse fuse = new PlasmaVaultRequestSharesFuse(marketId);

            // Use PlasmaVaultMock so storage context is shared
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Grant plasmaVault as substrate in vault's storage
            address[] memory assets = new address[](1);
            assets[0] = plasmaVault;
            vault.grantAssetsToMarket(marketId, assets);

            // Mock balanceOf on plasmaVault to return 0 (so finalSharesAmount = 0, early return)
            vm.mockCall(plasmaVault, abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(vault)), abi.encode(uint256(0)));

            PlasmaVaultRequestSharesFuseEnterData memory data_ = PlasmaVaultRequestSharesFuseEnterData({
                sharesAmount: 1,
                plasmaVault: plasmaVault
            });

            // Call via vault
            (bool success, bytes memory result) = address(vault).call(
                abi.encodeWithSelector(PlasmaVaultRequestSharesFuse.enter.selector, data_)
            );
            assertTrue(success, "enter should not revert");
            (address returnedPlasmaVault, uint256 returnedSharesAmount) = abi.decode(result, (address, uint256));

            assertEq(returnedPlasmaVault, plasmaVault, "plasmaVault should match input");
            assertEq(returnedSharesAmount, 0, "sharesAmount should be clamped to zero when no balance");
        }

    function test_enterTransient_hits_if_true_branch_and_sets_outputs() public {
            // given
            uint256 marketId = 1;
            PlasmaVaultRequestSharesFuse fuse = new PlasmaVaultRequestSharesFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // prepare inputs via vault: sharesAmount=0 for early return
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0)); // sharesAmount = 0
            inputs[1] = TypeConversionLib.toBytes32(address(0x1234)); // plasmaVault address
            vault.setInputs(fuse.VERSION(), inputs);

            // when: delegatecall enterTransient through vault
            vault.enterCompoundV2SupplyTransient();

            // then
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length should be 2");
            address returnedPlasmaVault = TypeConversionLib.toAddress(outputs[0]);
            uint256 returnedSharesAmount = TypeConversionLib.toUint256(outputs[1]);
            assertEq(returnedPlasmaVault, address(0x1234), "plasmaVault should match input");
            assertEq(returnedSharesAmount, 0, "sharesAmount should be zero on early return through transient path");
        }
}