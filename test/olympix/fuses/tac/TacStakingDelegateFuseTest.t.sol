// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {TacStakingDelegateFuse} from "../../../../contracts/fuses/tac/TacStakingDelegateFuse.sol";

import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {TacValidatorAddressConverter} from "contracts/fuses/tac/lib/TacValidatorAddressConverter.sol";
import {TacStakingDelegateFuse, TacStakingDelegateFuseEnterData} from "contracts/fuses/tac/TacStakingDelegateFuse.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {TacStakingDelegateFuseEnterData} from "contracts/fuses/tac/TacStakingDelegateFuse.sol";
import {TacStakingStorageLib} from "contracts/fuses/tac/lib/TacStakingStorageLib.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingDelegator} from "contracts/fuses/tac/TacStakingDelegator.sol";
import {TacStakingDelegateFuseExitData} from "contracts/fuses/tac/TacStakingDelegateFuse.sol";
import {TacStakingDelegateFuse} from "contracts/fuses/tac/TacStakingDelegateFuse.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
contract TacStakingDelegateFuseTest is OlympixUnitTest("TacStakingDelegateFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_RevertsOnEmptyValidatorArray() public {
        // arrange: deploy wTAC mock and fuse
        MockERC20 wTac = new MockERC20("Wrapped TAC", "wTAC", 18);
        TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(1, address(wTac), address(0x1234));
    
        // grant some dummy substrates so other validations are irrelevant
        string memory validator = "tacvaloper1dummyvalidator";
        (bytes32 firstSlot, bytes32 secondSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(validator);
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = firstSlot;
        substrates[1] = secondSlot;
        PlasmaVaultConfigLib.grantMarketSubstrates(1, substrates);
    
        // act / assert: empty arrays should trigger TacStakingFuseEmptyArray revert
        TacStakingDelegateFuseEnterData memory data_;
        data_.validatorAddresses = new string[](0);
        data_.wTacAmounts = new uint256[](0);
    
        vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseEmptyArray.selector);
        fuse.enter(data_);
    }

    function test_enter_RevertsOnArrayLengthMismatch_opix_target_branch_79_true() public {
            // arrange: create mock wTAC and fuse
            MockERC20 wTac = new MockERC20("Wrapped TAC", "wTAC", 18);
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(1, address(wTac), address(0x1234));
    
            // prepare data with mismatched lengths: 1 validator, 2 amounts
            TacStakingDelegateFuseEnterData memory data_;
            data_.validatorAddresses = new string[](1);
            data_.validatorAddresses[0] = "tacvaloper1dummyvalidator"; // concrete literal to avoid type/import issues
            data_.wTacAmounts = new uint256[](2);
            data_.wTacAmounts[0] = 1 ether;
            data_.wTacAmounts[1] = 2 ether;
    
            // expect revert from the array length mismatch branch (opix-target-branch-79-True)
            vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseArrayLengthMismatch.selector);
            fuse.enter(data_);
        }

    function test_enter_ArrayLengthMatchHitsElseBranchAndDelegates() public {
            // arrange
            uint256 marketId = 1;
            MockERC20 wTac = new MockERC20("Wrapped TAC", "wTAC", 18);
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(marketId, address(wTac), address(0x1234));

            string memory validator = "tacvaloper1dummyvalidator";

            // prepare data with matching array lengths (non-zero and equal)
            string[] memory validators = new string[](1);
            uint256[] memory amounts = new uint256[](1);
            validators[0] = validator;
            amounts[0] = 100 ether;

            TacStakingDelegateFuseEnterData memory data_ = TacStakingDelegateFuseEnterData({
                validatorAddresses: validators,
                wTacAmounts: amounts
            });

            // act: array lengths match so the length-mismatch branch is NOT taken;
            // execution proceeds to substrate validation which reverts (substrates
            // not granted in the fuse's storage context), proving the else branch was hit
            vm.expectRevert(abi.encodeWithSelector(TacStakingDelegateFuse.TacStakingFuseSubstrateNotGranted.selector, validator));
            fuse.enter(data_);
        }

    function test_exit_RevertsOnEmptyValidatorArray() public {
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(1, address(0x1), address(0x2));
    
            string[] memory validators = new string[](0);
            uint256[] memory amounts = new uint256[](0);
    
            TacStakingDelegateFuseExitData memory data_ = TacStakingDelegateFuseExitData({
                validatorAddresses: validators,
                tacAmounts: amounts
            });
    
            vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseEmptyArray.selector);
            fuse.exit(data_);
        }

    function test_exit_ArrayLengthMismatch_RevertsTacStakingFuseArrayLengthMismatch() public {
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(1, address(0x1), address(0x2));
    
            // validatorAddresses length != tacAmounts length to make the if condition true
            string[] memory validators = new string[](2);
            validators[0] = "val1";
            validators[1] = "val2";
    
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;
    
            TacStakingDelegateFuseExitData memory data_ = TacStakingDelegateFuseExitData({
                validatorAddresses: validators,
                tacAmounts: amounts
            });
    
            vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseArrayLengthMismatch.selector);
            fuse.exit(data_);
        }

    function test_exit_RevertsWhenDelegatorAddressIsZero() public {
            // arrange
            uint256 marketId = 1;
            MockERC20 wTac = new MockERC20("Wrapped TAC", "wTAC", 18);
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(marketId, address(wTac), address(0x1234));
    
            // make sure delegator is zero so the if (delegator == address(0)) branch is taken
            TacStakingStorageLib.setTacStakingDelegator(address(0));
    
            // prepare non‑empty, length‑matched arrays so we pass previous checks
            string[] memory validators = new string[](1);
            validators[0] = "validator-1";
            uint256[] memory amounts = new uint256[](1);
            amounts[0] = 1 ether;
    
            TacStakingDelegateFuseExitData memory data_ = TacStakingDelegateFuseExitData({
                validatorAddresses: validators,
                tacAmounts: amounts
            });
    
            // assert: exit should revert with TacStakingFuseInvalidDelegatorAddress when delegator == address(0)
            vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseInvalidDelegatorAddress.selector);
            fuse.exit(data_);
        }

    function test_instantWithdraw_ZeroAmountHitsEarlyReturnBranch() public {
            // Arrange: create fuse with dummy params
            uint256 marketId = 1;
            address wTac = address(0x1234);
            address staking = address(0x5678);
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(marketId, wTac, staking);
    
            // Set a non-zero delegator so that if we ever got past the zero-amount branch
            // the code would not revert on delegator == address(0). This ensures that
            // the test only passes because of the early return when wTacAmount == 0.
            TacStakingStorageLib.setTacStakingDelegator(address(0xdead));
    
            // Act: call instantWithdraw with params_[0] == 0 to take the opix-target-branch-165-True path
            bytes32[] memory params = new bytes32[](1);
            params[0] = bytes32(uint256(0));
    
            fuse.instantWithdraw(params);
    
            // Assert: nothing to assert explicitly; lack of revert confirms we hit the early-return branch
        }

    function test_instantWithdraw_NonZeroAmountHitsElseBranchAndRevertsOnZeroDelegator() public {
            // Arrange: create fuse with dummy params
            uint256 marketId = 1;
            address wTac = address(0x1234);
            address staking = address(0x5678);
            TacStakingDelegateFuse fuse = new TacStakingDelegateFuse(marketId, wTac, staking);
    
            // Ensure delegator is zero so that after taking the non-zero amount branch
            // the function will hit the delegator == address(0) check and revert
            // with TacStakingFuseInvalidDelegatorAddress.
            TacStakingStorageLib.setTacStakingDelegator(address(0));
    
            // Act: call instantWithdraw with params_[0] > 0 so that
            // we bypass the early return and enter the else-branch
            bytes32[] memory params = new bytes32[](1);
            params[0] = bytes32(uint256(1));
    
            vm.expectRevert(TacStakingDelegateFuse.TacStakingFuseInvalidDelegatorAddress.selector);
            fuse.instantWithdraw(params);
        }
}