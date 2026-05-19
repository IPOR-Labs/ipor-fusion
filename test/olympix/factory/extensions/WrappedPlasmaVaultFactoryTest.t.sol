// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "test/OlympixUnitTest.sol";

/// @dev Target contract: contracts/factory/extensions/WrappedPlasmaVaultFactory.sol

import {WrappedPlasmaVaultFactory} from "contracts/factory/extensions/WrappedPlasmaVaultFactory.sol";

import {MockToken} from "test/managers/MockToken.sol";
import {MockPlasmaVault} from "test/managers/MockPlasmaVault.sol";
import {WrappedPlasmaVault} from "contracts/vaults/extensions/WrappedPlasmaVault.sol";
contract WrappedPlasmaVaultFactoryTest is OlympixUnitTest("WrappedPlasmaVaultFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_create_RevertWhen_PerformanceFeeAccountZeroHitsPerformanceFeeAccountCheck() public {
            // Deploy implementation (initializer already disabled in constructor for non-proxy usage)
            WrappedPlasmaVaultFactory factory = new WrappedPlasmaVaultFactory();
    
            // Valid non-zero parameters except performanceFeeAccount_ which is zero
            string memory name_ = "Wrapped PV";
            string memory symbol_ = "WPV";
            address plasmaVault_ = address(0x1); // non-zero to pass plasmaVault_ check
            address wrappedPlasmaVaultOwner_ = address(0x2); // non-zero to pass owner check
            address managementFeeAccount_ = address(0x3); // non-zero to pass managementFeeAccount_ check
            uint256 managementFeePercentage_ = 100; // within bounds
            address performanceFeeAccount_ = address(0); // zero to trigger InvalidAddress at performanceFeeAccount_ check
            uint256 performanceFeePercentage_ = 100; // within bounds
    
            // Expect revert from the factory's InvalidAddress error at performanceFeeAccount_ check
            vm.expectRevert(WrappedPlasmaVaultFactory.InvalidAddress.selector);
            factory.create(
                name_,
                symbol_,
                plasmaVault_,
                wrappedPlasmaVaultOwner_,
                managementFeeAccount_,
                managementFeePercentage_,
                performanceFeeAccount_,
                performanceFeePercentage_
            );
        }

    function test_create_RevertWhen_ManagementFeePercentageAboveMaxHitsInvalidFeePercentageBranch() public {
            // Deploy mocks for underlying asset and plasma vault
            MockToken underlying = new MockToken("Mock", "MOCK");
            MockPlasmaVault plasmaVault = new MockPlasmaVault(address(underlying));
    
            // Deploy factory implementation (initializer disabled in constructor for non-proxy usage)
            WrappedPlasmaVaultFactory factory = new WrappedPlasmaVaultFactory();
    
            // Parameters: all valid except managementFeePercentage_ which exceeds 10000 to hit the branch
            string memory name_ = "Wrapped PV";
            string memory symbol_ = "WPV";
            address plasmaVault_ = address(plasmaVault);
            address wrappedPlasmaVaultOwner_ = address(0x2);
            address managementFeeAccount_ = address(0x3);
            uint256 managementFeePercentage_ = 10001; // > 10000 to trigger InvalidFeePercentage at opix-target-branch-79-True
            address performanceFeeAccount_ = address(0x4);
            uint256 performanceFeePercentage_ = 100; // within bounds
    
            vm.expectRevert(WrappedPlasmaVaultFactory.InvalidFeePercentage.selector);
            factory.create(
                name_,
                symbol_,
                plasmaVault_,
                wrappedPlasmaVaultOwner_,
                managementFeeAccount_,
                managementFeePercentage_,
                performanceFeeAccount_,
                performanceFeePercentage_
            );
        }

    function test_create_RevertWhen_PerformanceFeePercentageAboveMax_HitsTargetBranch80True() public {
            // arrange: valid underlying and plasma vault
            MockToken underlying = new MockToken("Mock", "MOCK");
            MockPlasmaVault plasmaVault = new MockPlasmaVault(address(underlying));
    
            // use factory implementation directly (constructor disables initializers, but create() is usable)
            WrappedPlasmaVaultFactory factory = new WrappedPlasmaVaultFactory();
    
            string memory name_ = "Wrapped PV";
            string memory symbol_ = "WPV";
            address plasmaVault_ = address(plasmaVault); // non-zero
            address wrappedPlasmaVaultOwner_ = address(0x2); // non-zero
            address managementFeeAccount_ = address(0x3); // non-zero
            uint256 managementFeePercentage_ = 100; // within bounds
            address performanceFeeAccount_ = address(0x4); // non-zero
            uint256 performanceFeePercentage_ = 10001; // > 10000 to trigger InvalidFeePercentage at opix-target-branch-80-True
    
            vm.expectRevert(WrappedPlasmaVaultFactory.InvalidFeePercentage.selector);
            factory.create(
                name_,
                symbol_,
                plasmaVault_,
                wrappedPlasmaVaultOwner_,
                managementFeeAccount_,
                managementFeePercentage_,
                performanceFeeAccount_,
                performanceFeePercentage_
            );
        }
}