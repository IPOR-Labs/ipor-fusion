// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {AerodromeGaugeFuse} from "../../../../contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";

import {AerodromeGaugeFuseEnterData} from "contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";
import {AerodromeGaugeFuse} from "contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";
import {AerodromeGaugeFuseExitData} from "contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";
import {AerodromeGaugeFuseEnterData, AerodromeGaugeFuseExitData} from "contracts/fuses/aerodrome/AerodromeGaugeFuse.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "contracts/fuses/aerodrome/AreodromeLib.sol";
import {IGauge} from "contracts/fuses/aerodrome/ext/IGauge.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {TransientStorageLibMock} from "test/transient_storage/TransientStorageLibMock.sol";
contract AerodromeGaugeFuseTest is OlympixUnitTest("AerodromeGaugeFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertWhenGaugeAddressIsZero() public {
            AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({gaugeAddress: address(0), amount: 1});
    
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(1);
    
            vm.expectRevert(AerodromeGaugeFuse.AerodromeGaugeFuseInvalidGauge.selector);
            fuse.enter(data_);
        }

    function test_enter_ElseBranchGaugeNonZeroAmountZero() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
            address gaugeAddress = address(0x1234);
    
            AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({
                gaugeAddress: gaugeAddress,
                amount: 0
            });
    
            (address returnedGauge, uint256 returnedAmount) = fuse.enter(data_);
    
            assertEq(returnedGauge, gaugeAddress, "Gauge address should be returned correctly");
            assertEq(returnedAmount, 0, "Amount should be zero when input amount is zero");
        }

    function test_enter_AmountNonZero_TakesElseBranchAndRevertsOnUnsupportedGauge() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);

            AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({
                gaugeAddress: address(0x1234),
                amount: 1
            });

            vm.expectRevert(abi.encodeWithSelector(AerodromeGaugeFuse.AerodromeGaugeFuseUnsupportedGauge.selector, "enter", address(0x1234)));
            fuse.enter(data_);
        }

    function test_exit_RevertsOnZeroGaugeAddress() public {
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(1);
    
            AerodromeGaugeFuseExitData memory data_ = AerodromeGaugeFuseExitData({
                gaugeAddress: address(0),
                amount: 100
            });
    
            vm.expectRevert(AerodromeGaugeFuse.AerodromeGaugeFuseInvalidGauge.selector);
            fuse.exit(data_);
        }

    function test_exit_WhenAmountIsZero_ShouldReturnEarlyAndNotCallGauge() public {
            // given
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
            // Prepare a dummy gauge address and mark it as granted substrate
            address gauge = address(0x1234);
            bytes32 substrate = AerodromeSubstrateLib.substrateToBytes32(
                AerodromeSubstrate({
                    substrateType: AerodromeSubstrateType.Gauge,
                    substrateAddress: gauge
                })
            );
    
            // Directly set substrate granted in storage so that, if reached, the check would pass
            PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId).substrateAllowances[substrate] = 1;
    
            // when
            // Call exit with amount == 0 to hit the `if (data_.amount == 0)` early-return branch
            (address returnedGauge, uint256 returnedAmount) =
                fuse.exit(AerodromeGaugeFuseExitData({gaugeAddress: gauge, amount: 0}));
    
            // then
            // Should return the gauge address and zero amount
            assertEq(returnedGauge, gauge, "Gauge address should be returned correctly");
            assertEq(returnedAmount, 0, "Amount should be zero when input amount is zero");
        }

    function test_exit_WhenAmountNonZero_EntersElseBranchAndWithdrawsWithZeroBalance() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);

            address gauge = address(0x1234);
            bytes32 substrate = AerodromeSubstrateLib.substrateToBytes32(
                AerodromeSubstrate({
                    substrateType: AerodromeSubstrateType.Gauge,
                    substrateAddress: gauge
                })
            );

            PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId).substrateAllowances[substrate] = 1;

            // Mock gauge.balanceOf to return 0 so amountToWithdraw = 0
            vm.mockCall(gauge, abi.encodeWithSelector(IGauge.balanceOf.selector, address(this)), abi.encode(uint256(0)));

            // Use delegatecall so storage reads (substrate check) use this contract's storage
            (bool success, bytes memory result) = address(fuse).delegatecall(
                abi.encodeWithSelector(AerodromeGaugeFuse.exit.selector, AerodromeGaugeFuseExitData({gaugeAddress: gauge, amount: 100}))
            );
            assertTrue(success, "delegatecall to exit should succeed");

            (address returnedGauge, uint256 returnedAmount) = abi.decode(result, (address, uint256));
            assertEq(returnedGauge, gauge, "Gauge address should be returned correctly when amount > 0");
            assertEq(returnedAmount, 0, "Returned amount should be zero when there is no gauge balance");
        }

    function test_enterTransient_branch207True_WritesOutputs() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);

            address gaugeAddress = address(0x1234);
            uint256 amount = 0;

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(gaugeAddress);
            inputs[1] = TypeConversionLib.toBytes32(amount);

            // Set transient inputs in this contract's context (keyed by fuse address = VERSION)
            TransientStorageLib.setInputs(address(fuse), inputs);

            // Use delegatecall so transient storage reads/writes happen in this contract's context
            (bool success,) = address(fuse).delegatecall(abi.encodeWithSignature("enterTransient()"));
            assertTrue(success, "enterTransient delegatecall should succeed");

            // Read outputs from this contract's transient storage
            bytes32[] memory outputs = TransientStorageLib.getOutputs(address(fuse));
            assertEq(outputs.length, 2, "outputs length should be 2");
            assertEq(TypeConversionLib.toAddress(outputs[0]), gaugeAddress, "output gauge address mismatch");
            assertEq(TypeConversionLib.toUint256(outputs[1]), amount, "output amount mismatch");
        }

    function test_exitTransient_TrueBranch_UsesInputsAndSetsOutputs() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);

            address gauge = address(0x1234);
            uint256 amount = 0;

            bytes32[] memory inputs = new bytes32[](2);
            inputs[0] = TypeConversionLib.toBytes32(gauge);
            inputs[1] = TypeConversionLib.toBytes32(amount);

            // Set transient inputs in this contract's context (keyed by fuse address = VERSION)
            TransientStorageLib.setInputs(address(fuse), inputs);

            // Use delegatecall so transient storage reads/writes happen in this contract's context
            (bool success,) = address(fuse).delegatecall(abi.encodeWithSignature("exitTransient()"));
            assertTrue(success, "delegatecall to exitTransient should succeed");

            // Read outputs from this contract's transient storage
            bytes32[] memory outputs = TransientStorageLib.getOutputs(address(fuse));
            assertEq(outputs.length, 2, "outputs length should be 2");
            assertEq(TypeConversionLib.toAddress(outputs[0]), gauge, "output gauge address should match input");
            assertEq(TypeConversionLib.toUint256(outputs[1]), amount, "output amount should match input (0)");
        }
}