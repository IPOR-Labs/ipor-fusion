// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {WhitelistWrappedPlasmaVaultFactory} from "../../../../contracts/factory/extensions/WhitelistWrappedPlasmaVaultFactory.sol";

import {WhitelistWrappedPlasmaVaultFactory} from "contracts/factory/extensions/WhitelistWrappedPlasmaVaultFactory.sol";
import {Ownable2StepUpgradeable} from "node_modules/@chainlink/contracts/node_modules/@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
contract WhitelistWrappedPlasmaVaultFactoryTest is OlympixUnitTest("WhitelistWrappedPlasmaVaultFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_RevertWhen_PerformanceFeeAccountIsZero() public {
            // Deploy minimal proxy instance for the upgradeable factory implementation
            WhitelistWrappedPlasmaVaultFactory implementation = new WhitelistWrappedPlasmaVaultFactory();
    
            // Initialize via delegatecall context using the test contract as the proxy context.
            // This avoids the InvalidInitialization() revert caused by calling initialize directly
            // on the implementation (which is already initialized in its constructor via OZ pattern).
            (bool success,) = address(implementation).delegatecall(
                abi.encodeWithSignature("initialize(address)", address(this))
            );
            require(success, "Initialization failed");
    
            vm.expectRevert(WhitelistWrappedPlasmaVaultFactory.InvalidAddress.selector);
    
            implementation.create(
                "Name",
                "SYM",
                address(0x1),
                address(0x2),
                address(0x3),
                100,
                address(0),
                100
            );
        }

    function test_create_RevertWhen_ManagementFeePercentageTooHigh() public {
            // arrange: deploy implementation and initialize via delegatecall so that
            // storage (including ownership) is set in the test contract context
            WhitelistWrappedPlasmaVaultFactory implementation = new WhitelistWrappedPlasmaVaultFactory();
    
            (bool ok,) = address(implementation).delegatecall(
                abi.encodeWithSignature("initialize(address)", address(this))
            );
            require(ok, "initialize failed");
    
            // act & assert: managementFeePercentage_ > 10000 should revert with InvalidFeePercentage
            vm.expectRevert(WhitelistWrappedPlasmaVaultFactory.InvalidFeePercentage.selector);
            implementation.create(
                "Name",
                "SYM",
                address(0x1),
                address(0x2),
                address(0x3),
                10001,
                address(0x4),
                100
            );
        }

    function test_create_RevertWhen_PerformanceFeePercentageTooHigh() public {
            // arrange: deploy implementation and initialize via delegatecall so that
            // storage (including ownership) is set in the test contract context
            WhitelistWrappedPlasmaVaultFactory implementation = new WhitelistWrappedPlasmaVaultFactory();
    
            (bool ok,) = address(implementation).delegatecall(
                abi.encodeWithSignature("initialize(address)", address(this))
            );
            require(ok, "initialize failed");
    
            // act & assert: performanceFeePercentage_ > 10000 should revert with InvalidFeePercentage
            vm.expectRevert(WhitelistWrappedPlasmaVaultFactory.InvalidFeePercentage.selector);
            implementation.create(
                "Name",
                "SYM",
                address(0x1),    // plasmaVault_
                address(0x2),    // initialAdmin_
                address(0x3),    // managementFeeAccount_
                100,             // managementFeePercentage_
                address(0x4),    // performanceFeeAccount_
                10001            // performanceFeePercentage_ (too high -> revert)
            );
        }
}