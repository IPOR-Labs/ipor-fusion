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

    function test_enter_supportedGauge_takesElseBranchOfMarketSubstrateCheck() public {
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

        // Mock stakingToken to return non-zero so we pass that check
        address stakingToken = address(0xABCD);
        vm.mockCall(gauge, abi.encodeWithSelector(IGauge.stakingToken.selector), abi.encode(stakingToken));
        // Mock balanceOf to return 0 so amountToDeposit=0 and we hit early return
        vm.mockCall(stakingToken, abi.encodeWithSignature("balanceOf(address)", address(this)), abi.encode(uint256(0)));

        AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({
            gaugeAddress: gauge,
            amount: 1
        });

        (bool success,) = address(fuse).delegatecall(
            abi.encodeWithSelector(AerodromeGaugeFuse.enter.selector, data_)
        );

        assertTrue(success, "enter should not revert when gauge substrate is granted");
    }

    function test_enter_StakingTokenZeroHitsIfBranch116True() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
            // Prepare gauge as granted substrate so unsupported-gauge check passes
            address gauge = address(0x1234);
            bytes32 substrate = AerodromeSubstrateLib.substrateToBytes32(
                AerodromeSubstrate({
                    substrateType: AerodromeSubstrateType.Gauge,
                    substrateAddress: gauge
                })
            );
            PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId).substrateAllowances[substrate] = 1;
    
            // Mock stakingToken() to return zero address so `if (stakingToken == address(0))` is true
            vm.mockCall(
                gauge,
                abi.encodeWithSelector(IGauge.stakingToken.selector),
                abi.encode(address(0))
            );
    
            AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({
                gaugeAddress: gauge,
                amount: 1
            });
    
            // delegatecall so storage for substrateAllowances is this test's storage
            (bool success,) = address(fuse).delegatecall(
                abi.encodeWithSelector(AerodromeGaugeFuse.enter.selector, data_)
            );
            // vm.expectRevert doesn't work with low-level delegatecall, so check success=false
            assertTrue(!success, "enter should revert when stakingToken is zero");
        }

    function test_enter_AmountNonZeroButBalanceZero_TakesBranch126True() public {
        uint256 marketId = 1;
        AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
        // prepare supported gauge substrate so the unsupported-gauge check is false (else-branch hit)
        address gauge = address(0x1234);
        bytes32 substrate = AerodromeSubstrateLib.substrateToBytes32(
            AerodromeSubstrate({substrateType: AerodromeSubstrateType.Gauge, substrateAddress: gauge})
        );
        PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId).substrateAllowances[substrate] = 1;
    
        // mock stakingToken() to return some non‑zero token address
        address stakingToken = address(0xABCD);
        vm.mockCall(gauge, abi.encodeWithSelector(IGauge.stakingToken.selector), abi.encode(stakingToken));
        // mock balanceOf(this) of stakingToken to be 0 so amountToDeposit = 0 and branch `if (amountToDeposit == 0)` is true
        vm.mockCall(stakingToken, abi.encodeWithSelector(bytes4(keccak256("balanceOf(address)")), address(this)), abi.encode(uint256(0)));
    
        AerodromeGaugeFuseEnterData memory data_ = AerodromeGaugeFuseEnterData({gaugeAddress: gauge, amount: 100});
    
        // call via delegatecall so PlasmaVaultConfigLib storage mappings are read from this contract
        (bool success, bytes memory ret) = address(fuse).delegatecall(
            abi.encodeWithSelector(AerodromeGaugeFuse.enter.selector, data_)
        );
        assertTrue(success, "enter should not revert when balance is zero");
    
        (address returnedGauge, uint256 returnedAmount) = abi.decode(ret, (address, uint256));
        assertEq(returnedGauge, gauge, "Gauge address should be returned correctly");
        assertEq(returnedAmount, 0, "Returned amount should be zero when staking token balance is zero");
    }

    function test_exit_RevertsOnUnsupportedGauge_Branch169True() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
            // gauge is NOT granted as substrate -> isMarketSubstrateGranted returns false
            address gauge = address(0x1234);
    
            AerodromeGaugeFuseExitData memory data_ = AerodromeGaugeFuseExitData({
                gaugeAddress: gauge,
                amount: 100
            });
    
            vm.expectRevert(
                abi.encodeWithSelector(
                    AerodromeGaugeFuse.AerodromeGaugeFuseUnsupportedGauge.selector,
                    "exit",
                    gauge
                )
            );
    
            fuse.exit(data_);
        }

    function test_exit_AmountNonZero_EntersElseBranch189() public {
            uint256 marketId = 1;
            AerodromeGaugeFuse fuse = new AerodromeGaugeFuse(marketId);
    
            address gauge = address(0x1234);
            bytes32 substrate = AerodromeSubstrateLib.substrateToBytes32(
                AerodromeSubstrate({substrateType: AerodromeSubstrateType.Gauge, substrateAddress: gauge})
            );
    
            // Grant substrate so isMarketSubstrateGranted returns true (we enter the `else` branch after the check)
            PlasmaVaultConfigLib.getMarketSubstratesStorage(marketId).substrateAllowances[substrate] = 1;
    
            // Mock gauge.balanceOf(this) to return a positive balance so amountToWithdraw > 0
            vm.mockCall(
                gauge,
                abi.encodeWithSelector(IGauge.balanceOf.selector, address(this)),
                abi.encode(uint256(50))
            );
    
            // Mock gauge.withdraw to succeed for the expected amount (20)
            vm.mockCall(gauge, abi.encodeWithSelector(IGauge.withdraw.selector, uint256(20)), "");
    
            // Call exit via delegatecall so that the library storage (substrateAllowances) read happens in this
            // test contract's storage, making the `if (amountToWithdraw == 0)` condition false and entering the else-branch
            (bool success, bytes memory result) = address(fuse).delegatecall(
                abi.encodeWithSelector(
                    AerodromeGaugeFuse.exit.selector,
                    AerodromeGaugeFuseExitData({gaugeAddress: gauge, amount: 20})
                )
            );
            assertTrue(success, "delegatecall to exit should succeed");
    
            (address returnedGauge, uint256 returnedAmount) = abi.decode(result, (address, uint256));
            assertEq(returnedGauge, gauge, "Gauge address should match input");
            assertEq(returnedAmount, 20, "Returned amount should equal requested non-zero amount");
        }
}