// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/fuses/chains/ethereum/lido/StEthWrapperFuse.sol

import {StEthWrapperFuse} from "contracts/fuses/chains/ethereum/lido/StEthWrapperFuse.sol";
import {Errors} from "contracts/libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "contracts/libraries/PlasmaVaultStorageLib.sol";
import {TransientStorageLib} from "contracts/transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "contracts/libraries/TypeConversionLib.sol";
import {MockERC20} from "test/test_helpers/MockERC20.sol";
import {IWstETH} from "contracts/fuses/chains/ethereum/lido/ext/IWstETH.sol";
import {PlasmaVaultConfigLib} from "contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultMock} from "test/fuses/PlasmaVaultMock.sol";
contract StEthWrapperFuseTest is OlympixUnitTest("StEthWrapperFuse") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_enter_zeroAmount_hitsEarlyReturnBranch() public {
            // Deploy fuse with non-zero marketId to avoid constructor revert
            StEthWrapperFuse fuse = new StEthWrapperFuse(1);
    
            // Call enter with amount = 0 to hit the `if (stEthAmount == 0)` true branch
            (uint256 finalAmount, uint256 wstEthAmount) = fuse.enter(0);
    
            // Assert that the function returned the early (0, 0) tuple
            assertEq(finalAmount, 0, "finalAmount should be zero for zero input");
            assertEq(wstEthAmount, 0, "wstEthAmount should be zero for zero input");
        }

    function test_enterTransient_hitsTrueBranchAndWritesOutputs() public {
            // deploy fuse with valid marketId
            StEthWrapperFuse fuse = new StEthWrapperFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // prepare input via transient storage (amount = 0 to early return before substrate check)
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0));
            vault.setInputs(address(fuse), inputs);

            // call enterTransient via vault (delegatecall) to share transient storage context
            StEthWrapperFuse(address(vault)).enterTransient();

            // read outputs back from transient storage and verify they were written
            bytes32[] memory outputs = vault.getOutputs(address(fuse));
            // should have exactly 2 outputs as per implementation
            assertEq(outputs.length, 2, "outputs length should be 2");
        }

    function test_exit_WhenAmountZero_ShouldReturnZerosAndNotRevert() public {
            // deploy fuse with non-zero marketId to pass constructor check
            StEthWrapperFuse fuse = new StEthWrapperFuse(1);
    
            // call exit with amount = 0 to hit `if (wstEthAmount == 0)` early-return branch
            (uint256 finalAmount, uint256 stEthAmount) = fuse.exit(0);
    
            // assert we indeed got zeros (branch executed)
            assertEq(finalAmount, 0, "finalAmount should be zero when input is zero");
            assertEq(stEthAmount, 0, "stEthAmount should be zero when input is zero");
        }

    function test_exitTransient_UsesTransientStorageAndHitsIfBranch() public {
            // Deploy fuse with valid marketId
            StEthWrapperFuse fuse = new StEthWrapperFuse(1);
            PlasmaVaultMock vault = new PlasmaVaultMock(address(fuse), address(0));

            // Prepare transient input (amount = 0 to early return before substrate check)
            bytes32[] memory inputs = new bytes32[](1);
            inputs[0] = TypeConversionLib.toBytes32(uint256(0));
            vault.setInputs(address(fuse), inputs);

            // Call exitTransient via vault (delegatecall) to share transient storage context
            StEthWrapperFuse(address(vault)).exitTransient();

            // Read outputs from transient storage
            bytes32[] memory outputs = vault.getOutputs(address(fuse));

            // exit(0) returns (0,0) immediately
            assertEq(outputs.length, 2, "outputs length");
            assertEq(outputs[0], bytes32(0), "finalAmount should be zero");
            assertEq(outputs[1], bytes32(0), "stEthAmount should be zero");
        }
}