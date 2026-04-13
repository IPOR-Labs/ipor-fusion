// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol

import {CurveChildLiquidityGaugeSupplyFuse} from "contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {CurveChildLiquidityGaugeSupplyFuseEnterData} from "contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {IChildLiquidityGauge} from "contracts/fuses/curve_gauge/ext/IChildLiquidityGauge.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {CurveChildLiquidityGaugeSupplyFuseExitData} from "contracts/fuses/curve_gauge/CurveChildLiquidityGaugeSupplyFuse.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract CurveChildLiquidityGaugeSupplyFuseTest is OlympixUnitTest("CurveChildLiquidityGaugeSupplyFuse") {


    function test_enter_revertsForUnsupportedGauge_opix_target_branch_59_true() public {
            // Arrange: deploy fuse with some marketId
            uint256 marketId = 1;
            CurveChildLiquidityGaugeSupplyFuse fuse = new CurveChildLiquidityGaugeSupplyFuse(marketId);
    
            // Use a dummy gauge address that is NOT granted as a substrate for this market
            address unsupportedGauge = address(0x1234);
    
            // Sanity check: ensure substrate is not granted in storage
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubs =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            // mapping default is 0, so isSubstrateAsAssetGranted will be false
            assertEq(marketSubs.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(unsupportedGauge)], 0);
    
            // Prepare enter data with non‑zero amount so that, if substrate were supported,
            // execution would continue past the first check
            CurveChildLiquidityGaugeSupplyFuseEnterData memory data_ = CurveChildLiquidityGaugeSupplyFuseEnterData({
                childLiquidityGauge: unsupportedGauge,
                lpTokenAmount: 1e18
            });
    
            // Expect revert from the first `if` in enter():
            // if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(...)) { revert CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge(...); }
            vm.expectRevert(
                abi.encodeWithSelector(
                    CurveChildLiquidityGaugeSupplyFuse.CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge.selector,
                    unsupportedGauge
                )
            );
    
            // Act: this must take the opix‑target-branch-59 True path and revert
            fuse.enter(data_);
        }

    function test_instantWithdraw_ZeroAmountBranch112True() public {
            // Deploy fuse with some MARKET_ID (0 is fine for this test)
            CurveChildLiquidityGaugeSupplyFuse fuse = new CurveChildLiquidityGaugeSupplyFuse(0);
    
            // Prepare params_ so that params_[0] == 0 and params_[1] is any bytes32 (gauge address not used)
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(uint256(0)); // amount = 0 to hit `if (amount == 0)` branch
            params[1] = bytes32(uint256(uint160(address(0x1234))));
    
            // Call should early-return and not revert
            fuse.instantWithdraw(params);
        }

    function test_instantWithdraw_NonZeroAmountBranch114False() public {
            // given: deploy fuse with MARKET_ID 0
            CurveChildLiquidityGaugeSupplyFuse fuse = new CurveChildLiquidityGaugeSupplyFuse(0);
    
            // prepare params so that amount != 0 (to skip the early return and enter the else-branch)
            bytes32[] memory params = new bytes32[](2);
            params[0] = bytes32(uint256(1)); // non-zero amount to make `if (amount == 0)` condition false
            params[1] = bytes32(uint256(uint160(address(0x1234)))); // gauge address, will be used in call but test only cares about branch
    
            // we expect a revert from further logic (unsupported gauge / balance checks),
            // but the important part is that execution reaches past the amount==0 check
            vm.expectRevert();
            fuse.instantWithdraw(params);
        }

    function test_exitTransient_writesOutputs_opix_target_branch_152_true() public {
            // Arrange
            uint256 marketId = 1;
            CurveChildLiquidityGaugeSupplyFuse fuse = new CurveChildLiquidityGaugeSupplyFuse(marketId);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            address gauge = address(0x1234);

            // Grant gauge as substrate and use lpAmount=0 for early return
            address[] memory assets = new address[](1);
            assets[0] = gauge;
            vault.grantAssetsToMarket(marketId, assets);

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(gauge);
            inputs[1] = TypeConversionLib.toBytes32(uint256(0)); // lpAmount=0 for early return

            vault.setInputs(fuse.VERSION(), inputs);

            // Act: delegatecall exitTransient through vault
            vault.exitCompoundV2SupplyTransient();

            // Assert: outputs written
            bytes32[] memory outputs = vault.getOutputs(fuse.VERSION());
            assertEq(outputs.length, 2, "outputs length");
            assertEq(TypeConversionLib.toAddress(outputs[0]), gauge, "gauge output");
            assertEq(TypeConversionLib.toUint256(outputs[1]), 0, "lpTokenAmount output");
        }

    function test_exit_revertsForUnsupportedGauge_opix_target_branch_175_true() public {
            // Arrange
            uint256 marketId = 1;
            CurveChildLiquidityGaugeSupplyFuse fuse = new CurveChildLiquidityGaugeSupplyFuse(marketId);
    
            // Use a dummy gauge address that is NOT granted as a substrate for this market
            address unsupportedGauge = address(0xABCD);
    
            // Sanity check: substrate not granted
            PlasmaVaultStorageLib.MarketSubstratesStruct storage marketSubs =
                PlasmaVaultStorageLib.getMarketSubstrates().value[marketId];
            assertEq(
                marketSubs.substrateAllowances[PlasmaVaultConfigLib.addressToBytes32(unsupportedGauge)],
                0
            );
    
            // Prepare exit data with non‑zero amount so the function reaches the substrate check
            CurveChildLiquidityGaugeSupplyFuseExitData memory data_ = CurveChildLiquidityGaugeSupplyFuseExitData({
                childLiquidityGauge: unsupportedGauge,
                lpTokenAmount: 1e18
            });
    
            // Expect revert from the first `if` in _exit():
            vm.expectRevert(
                abi.encodeWithSelector(
                    CurveChildLiquidityGaugeSupplyFuse.CurveChildLiquidityGaugeSupplyFuseUnsupportedGauge.selector,
                    unsupportedGauge
                )
            );
    
            // Act: this must take opix‑target-branch-175 True path and revert
            fuse.exit(data_);
        }
}