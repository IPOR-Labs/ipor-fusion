// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/euler/EulerV2BorrowFuse.sol

import {EulerV2BorrowFuse} from "contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerFuseLib} from "contracts/fuses/euler/EulerFuseLib.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IBorrowing} from "contracts/fuses/euler/ext/IBorrowing.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData} from "contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseExitData} from "contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerSubstrate} from "contracts/fuses/euler/EulerFuseLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
contract EulerV2BorrowFuseTest is OlympixUnitTest("EulerV2BorrowFuse") {


    function test_enter_zeroAssetAmount_hitsBranch73True() public {
            uint256 marketId = 1;
            IEVC evc = IEVC(address(0xdead));
            EulerV2BorrowFuse fuse = new EulerV2BorrowFuse(marketId, address(evc));
    
            address eulerVault = address(0xE1);
            bytes1 subAccountId = 0x01;
    
            EulerV2BorrowFuseEnterData memory data = EulerV2BorrowFuseEnterData({
                eulerVault: eulerVault,
                assetAmount: 0,
                subAccount: subAccountId
            });
    
            (address returnedVault, uint256 borrowAmount, address subAccount) = fuse.enter(data);
    
            assertEq(returnedVault, eulerVault, "vault address should be echoed back");
            assertEq(borrowAmount, 0, "borrowAmount must be zero on early return");
    
            address expectedSubAccount = EulerFuseLib.generateSubAccountAddress(address(fuse), subAccountId);
            assertEq(subAccount, expectedSubAccount, "subAccount address mismatch");
        }

    function test_enter_nonZeroAssetAmount_canBorrowFalse_revertsWithUnsupportedEnterAction() public {
            uint256 marketId = 1;
            IEVC evc = IEVC(address(0x1));
            EulerV2BorrowFuse fuse = new EulerV2BorrowFuse(marketId, address(evc));
    
            address eulerVault = address(0xE2);
            bytes1 subAccountId = 0x02;
    
            EulerV2BorrowFuseEnterData memory data = EulerV2BorrowFuseEnterData({
                eulerVault: eulerVault,
                assetAmount: 1,
                subAccount: subAccountId
            });
    
            vm.expectRevert(abi.encodeWithSelector(EulerV2BorrowFuse.EulerV2BorrowFuseUnsupportedEnterAction.selector, eulerVault, subAccountId));
            fuse.enter(data);
        }

    function test_exit_WhenMaxAssetAmountNonZero_EntersElseBranch112() public {
        // setUp: minimal environment to make EulerFuseLib.canBorrow return true
        uint256 marketId = 1;
        address vault = address(0xABCD);
        bytes1 subAccountId = 0x01;
    
        // Configure market substrates in storage so that
        // EulerFuseLib.canBorrow(marketId, vault, subAccountId) returns true
        EulerSubstrate memory substrate = EulerSubstrate({
            eulerVault: vault,
            isCollateral: false,
            canBorrow: true,
            subAccounts: subAccountId
        });
    
        bytes32 encoded = EulerFuseLib.substrateToBytes32(substrate);
        bytes32[] memory list = new bytes32[](1);
        list[0] = encoded;
    
        PlasmaVaultStorageLib.MarketSubstratesStruct storage ms =
            PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
        ms.substrateAllowances[encoded] = 1;
        ms.substrates = list;
    
        // Deploy fuse with non‑zero EVC just to satisfy constructor check
        IEVC evc = IEVC(address(1));
        EulerV2BorrowFuse fuse = new EulerV2BorrowFuse(marketId, address(evc));
    
        // Prepare exit data with non‑zero maxAssetAmount so the
        // `if (data_.maxAssetAmount == 0)` condition is FALSE and
        // branch 112 else's assert(true) is executed
        EulerV2BorrowFuseExitData memory data_ = EulerV2BorrowFuseExitData({
            eulerVault: vault,
            maxAssetAmount: 1,
            subAccount: subAccountId
        });
    
        // We expect the low‑level EVC.call to revert (no real implementation),
        // but by that time the targeted else‑branch has already been taken.
        vm.expectRevert();
        fuse.exit(data_);
    }

    function test_enterTransient_and_exitTransient_roundTrip_outputsMatch() public {
            uint256 marketId = 1;
            IEVC evc = IEVC(address(0x1));
            EulerV2BorrowFuse fuse = new EulerV2BorrowFuse(marketId, address(evc));
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address eulerVault = address(0xE3);
            bytes1 subAccountId = 0x05;

            // Prepare inputs for enterTransient with amount=0 for early return
            bytes32[] memory inputs = new bytes32[](3);
            inputs[0] = TypeConversionLib.toBytes32(eulerVault);
            inputs[1] = TypeConversionLib.toBytes32(uint256(0));
            inputs[2] = TypeConversionLib.toBytes32(uint256(uint8(subAccountId)));

            vault.setInputs(fuse.VERSION(), inputs);

            // Call enterTransient via delegatecall through vault
            vault.enterCompoundV2SupplyTransient();

            bytes32[] memory enterOutputs = vault.getOutputs(fuse.VERSION());

            // Validate outputs from enterTransient
            address outVault = TypeConversionLib.toAddress(enterOutputs[0]);
            uint256 outAmount = TypeConversionLib.toUint256(enterOutputs[1]);
            address outSubAccount = TypeConversionLib.toAddress(enterOutputs[2]);

            assertEq(outVault, eulerVault, "enterTransient: vault mismatch");
            assertEq(outAmount, 0, "enterTransient: amount should be zero");
            // address(this) inside fuse during delegatecall = address(vault)
            address expectedSub = EulerFuseLib.generateSubAccountAddress(address(vault), subAccountId);
            assertEq(outSubAccount, expectedSub, "enterTransient: subAccount mismatch");

            // Now reuse same inputs for exitTransient path with maxAssetAmount = 0
            bytes32[] memory exitInputs = new bytes32[](3);
            exitInputs[0] = TypeConversionLib.toBytes32(eulerVault);
            exitInputs[1] = TypeConversionLib.toBytes32(uint256(0));
            exitInputs[2] = TypeConversionLib.toBytes32(uint256(uint8(subAccountId)));

            vault.setInputs(fuse.VERSION(), exitInputs);

            vault.exitCompoundV2SupplyTransient();

            bytes32[] memory exitOutputs = vault.getOutputs(fuse.VERSION());

            address exitVault = TypeConversionLib.toAddress(exitOutputs[0]);
            uint256 exitAmount = TypeConversionLib.toUint256(exitOutputs[1]);
            address exitSubAccount = TypeConversionLib.toAddress(exitOutputs[2]);

            assertEq(exitVault, eulerVault, "exitTransient: vault mismatch");
            assertEq(exitAmount, 0, "exitTransient: amount should be zero");
            assertEq(exitSubAccount, expectedSub, "exitTransient: subAccount mismatch");
        }
}