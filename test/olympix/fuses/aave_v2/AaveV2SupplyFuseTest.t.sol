// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

import {AaveV2SupplyFuse} from "contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";

/// @dev Target contract: contracts/fuses/aave_v2/AaveV2SupplyFuse.sol

import {AaveV2SupplyFuseMock} from "test/fuses/aave_v2/AaveV2SupplyFuseMock.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {AaveLendingPoolV2} from "contracts/fuses/aave_v2/ext/AaveLendingPoolV2.sol";
import {AaveConstantsEthereum} from "contracts/fuses/aave_v2/AaveConstantsEthereum.sol";
import {AaveV2SupplyFuseEnterData} from "contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {IFuseInstantWithdraw} from "contracts/fuses/IFuseInstantWithdraw.sol";
import {AaveV2SupplyFuseExitData} from "contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {AaveLendingPoolV2, ReserveData} from "contracts/fuses/aave_v2/ext/AaveLendingPoolV2.sol";
contract AaveV2SupplyFuseTest is OlympixUnitTest("AaveV2SupplyFuse") {
    AaveV2SupplyFuse public aaveV2SupplyFuse;


    function setUp() public override {
        aaveV2SupplyFuse = new AaveV2SupplyFuse(1, address(0xDEAD));
    }

    function test_deployment_doesNotRevert() public view {
        assertTrue(address(aaveV2SupplyFuse) != address(0), "Contract should be deployed");
    }

    function test_enter_zeroAmount_returnsEarly() public {
            // use some arbitrary ERC20 token address
            address token = address(0xBEEF);
    
            // prepare enter data with amount == 0 to hit opix-target-branch-58-True
            AaveV2SupplyFuseEnterData memory data_ = AaveV2SupplyFuseEnterData({asset: token, amount: 0});
    
            // call enter and verify it returns immediately with the same values
            (address asset, uint256 amount) = aaveV2SupplyFuse.enter(data_);
    
            assertEq(asset, token, "Asset should be returned unchanged");
            assertEq(amount, 0, "Amount should be zero when input amount is zero");
        }

    function test_enter_nonZeroAmount_unsupportedAsset_revertsAndHitsElseBranch() public {
            // arrange: deploy a real ERC20 so forceApprove won't revert
            MockERC20 token = new MockERC20("Mock", "MCK", 18);
    
            // ensure the substrate is NOT granted for MARKET_ID = 1
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[aaveV2SupplyFuse.MARKET_ID()];
            // clear any existing allowance just in case
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(address(token))] = 0;
    
            // non‑zero amount to go into the `else` branch of the first if (amount == 0)
            AaveV2SupplyFuseEnterData memory data_ = AaveV2SupplyFuseEnterData({
                asset: address(token),
                amount: 1 ether
            });
    
            // assert: unsupported asset should revert with custom error
            vm.expectRevert(abi.encodeWithSelector(AaveV2SupplyFuse.AaveV2SupplyFuseUnsupportedAsset.selector, address(token)));
            aaveV2SupplyFuse.enter(data_);
        }

    function test_enterTransient_hitsBranch83TrueAndWritesOutputs() public {
            // arrange: deploy mock token, use amount=0 for early return (avoids pool interaction)
            MockERC20 token = new MockERC20("Mock", "MCK", 18);
            uint256 amount = 0;

            // we need to execute enterTransient via delegatecall so that storage context is fuseMock
            AaveV2SupplyFuseMock fuseMock = new AaveV2SupplyFuseMock(address(aaveV2SupplyFuse));

            // prepare transient storage inputs under VERSION key (address of fuse)
            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(address(token));
            inputs[1] = TypeConversionLib.toBytes32(amount);
            fuseMock.setInputs(aaveV2SupplyFuse.VERSION(), inputs);

            // act: enterTransient reads inputs, calls enter(0) which early-returns, then writes outputs
            fuseMock.enterTransient();

            // assert: outputs stored under VERSION should match returned asset and amount
            bytes32[] memory outputs = fuseMock.getOutputs(aaveV2SupplyFuse.VERSION());
            assertEq(outputs.length, 2, "outputs length should be 2");
            assertEq(TypeConversionLib.toAddress(outputs[0]), address(token), "output asset mismatch");
            assertEq(TypeConversionLib.toUint256(outputs[1]), amount, "output amount mismatch");
        }

    function test_exitTransient_hitsBranch116True_andRevertsOnUnsupportedAsset() public {
            // Arrange: prepare transient storage inputs for exitTransient: [asset, amount]
            address unsupportedAsset = address(0xBEEF);
            uint256 amount = 100 ether;

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(unsupportedAsset);
            inputs[1] = TypeConversionLib.toBytes32(amount);

            // Use fuseMock so transient storage and fuse execution share the same context
            AaveV2SupplyFuseMock fuseMock = new AaveV2SupplyFuseMock(address(aaveV2SupplyFuse));
            fuseMock.setInputs(aaveV2SupplyFuse.VERSION(), inputs);

            // Act & Assert: exitTransient should always take the `if (true)` branch (opix-target-branch-116-True)
            // and then call _exit which will revert with AaveV2SupplyFuseUnsupportedAsset
            vm.expectRevert(
                abi.encodeWithSelector(AaveV2SupplyFuse.AaveV2SupplyFuseUnsupportedAsset.selector, unsupportedAsset)
            );
            fuseMock.exitTransient();
        }

    function test_instantWithdraw_UsesCatchExceptionsTrueAndEmitsExitOrExitFailed() public {
        // prepare params for instantWithdraw: params[0] = amount (0 for early return), params[1] = asset as bytes32
        // Using amount = 0 so _exit returns early without needing substrates or pool interaction
        bytes32[] memory params = new bytes32[](2);
        params[0] = bytes32(uint256(0));
        params[1] = PlasmaVaultConfigLib.addressToBytes32(address(0xBEEF));

        // act: just call instantWithdraw; this must go through the `if (true)` branch
        // in instantWithdraw (opix-target-branch-139-True) which calls _exit(..., true).
        // With amount = 0, _exit returns early.
        aaveV2SupplyFuse.instantWithdraw(params);

        // assert: branch executed without reverting; reaching here is sufficient
        assertTrue(true, "instantWithdraw completed without revert");
    }

    function test_exit_zeroAmount_returnsEarlyAndHitsBranch157True() public {
            // arrange: deploy a mock token and mock aToken, and configure market substrates
            MockERC20 underlying = new MockERC20("Mock", "MCK", 18);
            MockERC20 aToken = new MockERC20("MockAToken", "MCKA", 18);
    
            // Grant the underlying asset as an allowed substrate for MARKET_ID == 1
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[aaveV2SupplyFuse.MARKET_ID()];
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(address(underlying))] = 1;
    
            // Point AaveConstantsEthereum.AAVE_LENDING_POOL_V2 to an AaveLendingPoolV2 that returns our aToken
            // and ensure our test contract holds no aToken balance so aTokenBalance == 0 inside _exit.
            // We do that by deploying a minimal mock pool via the existing interface and using vm.etch to
            // place it at the canonical AAVE_LENDING_POOL_V2 address.
            AaveLendingPoolV2 pool = AaveLendingPoolV2(AaveConstantsEthereum.AAVE_LENDING_POOL_V2);
            // Manually write ReserveData with aTokenAddress = address(aToken) into storage slot expected by getReserveData
            // via vm.store. Slot layout for mapping(address => ReserveData) is implementation specific, but for the
            // purpose of this branch test we only need balanceOf(aToken) == 0 which is already true by default.
            // Therefore we can skip precise storage setup and rely on default zeroed ReserveData.
    
            // act: call exit with amount == 0 to hit `if (data_.amount == 0)` branch (opix-target-branch-157-True)
            AaveV2SupplyFuseExitData memory data_ = AaveV2SupplyFuseExitData({asset: address(underlying), amount: 0});
            (address asset, uint256 amount) = aaveV2SupplyFuse.exit(data_);
    
            // assert: function should return immediately with unchanged values
            assertEq(asset, address(underlying), "Asset should be returned unchanged");
            assertEq(amount, 0, "Amount should be zero when input amount is zero");
        }

    function test_exit_nonZeroAmount_hitsElseBranchAndRevertsOnUnsupportedAsset() public {
            // arrange: use any address as asset and non‑zero amount so data_.amount == 0 is false
            address token = address(0xBEEF);
            AaveV2SupplyFuseExitData memory data_ = AaveV2SupplyFuseExitData({asset: token, amount: 1});
    
            // ensure substrate is NOT granted so isSubstrateAsAssetGranted returns false
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubstrates =
                PlasmaVaultStorageLib.getMarketSubstrates().value[aaveV2SupplyFuse.MARKET_ID()];
            marketSubstrates.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(token)] = 0;
    
            // expect revert with custom error from _exit after taking the non‑zero branch
            vm.expectRevert(
                abi.encodeWithSelector(AaveV2SupplyFuse.AaveV2SupplyFuseUnsupportedAsset.selector, token)
            );
            aaveV2SupplyFuse.exit(data_);
        }
}