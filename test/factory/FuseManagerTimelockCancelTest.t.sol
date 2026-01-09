// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {FusionFactory} from "../../contracts/factory/FusionFactory.sol";
import {FusionFactoryLib} from "../../contracts/factory/lib/FusionFactoryLib.sol";
import {FusionFactoryLogicLib} from "../../contracts/factory/lib/FusionFactoryLogicLib.sol";
import {RewardsManagerFactory} from "../../contracts/factory/RewardsManagerFactory.sol";
import {WithdrawManagerFactory} from "../../contracts/factory/WithdrawManagerFactory.sol";
import {ContextManagerFactory} from "../../contracts/factory/ContextManagerFactory.sol";
import {PriceManagerFactory} from "../../contracts/factory/PriceManagerFactory.sol";
import {PlasmaVaultFactory} from "../../contracts/factory/PlasmaVaultFactory.sol";
import {AccessManagerFactory} from "../../contracts/factory/AccessManagerFactory.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {MockERC20} from "../test_helpers/MockERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {BurnRequestFeeFuse} from "../../contracts/fuses/burn_request_fee/BurnRequestFeeFuse.sol";
import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FusionFactoryStorageLib} from "../../contracts/factory/lib/FusionFactoryStorageLib.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {FeeManager} from "../../contracts/managers/fee/FeeManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {FeeConfig} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";

/// @title FuseManagerTimelockCancelTest
/// @notice Test demonstrating FuseManager role with 24h timelock and guardian cancel functionality
/// @dev Uses FusionFactory to create a vault, then:
///      1. Sets up FUSE_MANAGER_ROLE with 24h timelock
///      2. Schedules adding a fuse
///      3. Guardian cancels the scheduled operation
///      4. Verifies the fuse was not added
contract FuseManagerTimelockCancelTest is Test {
    // Constants
    uint256 public constant TIMELOCK_24H = 24 hours;

    // Contracts
    FusionFactory public fusionFactory;
    FusionFactoryStorageLib.FactoryAddresses public factoryAddresses;
    MockERC20 public underlyingToken;

    // Addresses
    address public plasmaVaultBase;
    address public priceOracleMiddleware;
    address public burnRequestFeeFuse;
    address public burnRequestFeeBalanceFuse;

    // Users
    address public owner;
    address public daoFeeRecipient;
    address public adminOne;
    address public adminTwo;
    address public daoFeeManager;
    address public maintenanceManager;
    address public guardian;
    address public fuseManager;

    // Mock fuse address to be added
    address public mockFuseToAdd;

    function setUp() public {
        // Create users
        owner = makeAddr("owner");
        daoFeeRecipient = makeAddr("daoFeeRecipient");
        adminOne = makeAddr("adminOne");
        adminTwo = makeAddr("adminTwo");
        daoFeeManager = makeAddr("daoFeeManager");
        maintenanceManager = makeAddr("maintenanceManager");
        guardian = makeAddr("guardian");
        fuseManager = makeAddr("fuseManager");
        mockFuseToAdd = makeAddr("mockFuseToAdd");

        // Deploy mock token
        underlyingToken = new MockERC20("Test Token", "TEST", 18);

        // Deploy factory contracts
        factoryAddresses = FusionFactoryStorageLib.FactoryAddresses({
            accessManagerFactory: address(new AccessManagerFactory()),
            plasmaVaultFactory: address(new PlasmaVaultFactory()),
            feeManagerFactory: address(new FeeManagerFactory()),
            withdrawManagerFactory: address(new WithdrawManagerFactory()),
            rewardsManagerFactory: address(new RewardsManagerFactory()),
            contextManagerFactory: address(new ContextManagerFactory()),
            priceManagerFactory: address(new PriceManagerFactory())
        });

        address[] memory plasmaVaultAdminArray = new address[](2);
        plasmaVaultAdminArray[0] = adminOne;
        plasmaVaultAdminArray[1] = adminTwo;

        plasmaVaultBase = address(new PlasmaVaultBase());
        burnRequestFeeFuse = address(new BurnRequestFeeFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));
        burnRequestFeeBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.ZERO_BALANCE_MARKET));

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));
        priceOracleMiddleware = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        // Deploy implementation and proxy for FusionFactory
        FusionFactory fusionFactoryImplementation = new FusionFactory();
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address[],(address,address,address,address,address,address,address),address,address,address,address)",
            owner,
            plasmaVaultAdminArray,
            factoryAddresses,
            plasmaVaultBase,
            priceOracleMiddleware,
            burnRequestFeeFuse,
            burnRequestFeeBalanceFuse
        );
        fusionFactory = FusionFactory(address(new ERC1967Proxy(address(fusionFactoryImplementation), initData)));

        vm.startPrank(owner);
        fusionFactory.grantRole(fusionFactory.DAO_FEE_MANAGER_ROLE(), daoFeeManager);
        fusionFactory.grantRole(fusionFactory.MAINTENANCE_MANAGER_ROLE(), maintenanceManager);
        vm.stopPrank();

        vm.startPrank(daoFeeManager);
        fusionFactory.updateDaoFee(daoFeeRecipient, 333, 777);
        vm.stopPrank();

        address[] memory approvedAddresses = new address[](1);
        approvedAddresses[0] = address(1);

        address accessManagerBase = address(new IporFusionAccessManager(owner, 1 seconds));
        address withdrawManagerBase = address(new WithdrawManager(accessManagerBase));

        address contextManagerBase = address(new ContextManager(owner, approvedAddresses));
        address priceManagerBase = address(new PriceOracleMiddlewareManager(owner, priceOracleMiddleware));

        address plasmaVaultCoreBase = address(new PlasmaVault());
        PlasmaVault(plasmaVaultCoreBase).proxyInitialize(
            PlasmaVaultInitData({
                assetName: "fake",
                assetSymbol: "fake",
                underlyingToken: address(underlyingToken),
                priceOracleMiddleware: priceOracleMiddleware,
                feeConfig: FeeConfig({
                    feeFactory: factoryAddresses.feeManagerFactory,
                    iporDaoManagementFee: 111,
                    iporDaoPerformanceFee: 222,
                    iporDaoFeeRecipientAddress: address(this)
                }),
                accessManager: accessManagerBase,
                plasmaVaultBase: plasmaVaultBase,
                withdrawManager: withdrawManagerBase
            })
        );

        address rewardsManagerBase = address(new RewardsClaimManager(owner, plasmaVaultCoreBase));

        vm.startPrank(maintenanceManager);
        fusionFactory.updateBaseAddresses(
            1,
            plasmaVaultCoreBase,
            accessManagerBase,
            priceManagerBase,
            withdrawManagerBase,
            rewardsManagerBase,
            contextManagerBase
        );
        vm.stopPrank();
    }

    /// @notice Test scenario:
    ///         1. Create vault using FusionFactory
    ///         2. Set 24h timelock for FUSE_MANAGER_ROLE
    ///         3. Grant FUSE_MANAGER_ROLE to fuseManager with 24h execution delay
    ///         4. Grant GUARDIAN_ROLE to guardian
    ///         5. FuseManager schedules adding a fuse
    ///         6. Guardian cancels the scheduled operation
    ///         7. Verify the fuse was NOT added
    function testShouldCancelScheduledFuseAdditionByGuardian() public {
        // ============================
        // Step 1: Create vault using FusionFactory
        // ============================
        uint256 redemptionDelay = 1 seconds;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Test Vault",
            "TVAULT",
            address(underlyingToken),
            redemptionDelay,
            owner
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        PlasmaVault plasmaVault = PlasmaVault(payable(instance.plasmaVault));

        // ============================
        // Step 2: Set 24h timelock for FUSE_MANAGER_ROLE
        // ============================
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = Roles.FUSE_MANAGER_ROLE;

        uint256[] memory delays = new uint256[](1);
        delays[0] = TIMELOCK_24H;

        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roleIds, delays);

        // Verify timelock was set
        assertEq(
            accessManager.getMinimalExecutionDelayForRole(Roles.FUSE_MANAGER_ROLE),
            TIMELOCK_24H,
            "FUSE_MANAGER_ROLE should have 24h timelock"
        );

        // ============================
        // Step 3: Grant GUARDIAN_ROLE to guardian
        // ============================
        vm.prank(owner);
        accessManager.grantRole(Roles.GUARDIAN_ROLE, guardian, 0);

        // Verify guardian role
        (bool isGuardian, ) = accessManager.hasRole(Roles.GUARDIAN_ROLE, guardian);
        assertTrue(isGuardian, "Guardian should have GUARDIAN_ROLE");

        // ============================
        // Step 4: Grant FUSE_MANAGER_ROLE to fuseManager with 24h execution delay
        // ============================
        // First we need to get atomist to grant the role
        // The owner is the default atomist after vault creation

        // Grant ATOMIST_ROLE to owner first (owner has OWNER_ROLE which can grant ATOMIST_ROLE)
        vm.prank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);

        // Now owner (as atomist) can grant FUSE_MANAGER_ROLE
        vm.prank(owner);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, uint32(TIMELOCK_24H));

        // Verify fuse manager role
        (bool isFuseManager, uint32 executionDelay) = accessManager.hasRole(Roles.FUSE_MANAGER_ROLE, fuseManager);
        assertTrue(isFuseManager, "FuseManager should have FUSE_MANAGER_ROLE");
        assertEq(executionDelay, uint32(TIMELOCK_24H), "FuseManager should have 24h execution delay");

        // ============================
        // Step 5: Verify test fuse is NOT yet supported
        // ============================
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(mockFuseToAdd),
            "Test fuse should NOT be supported initially"
        );

        // ============================
        // Step 6: FuseManager schedules adding the fuse
        // ============================
        address target = address(plasmaVault);
        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = mockFuseToAdd;
        bytes memory data = abi.encodeWithSelector(PlasmaVaultGovernance.addFuses.selector, fusesToAdd);

        // Schedule the operation
        vm.prank(fuseManager);
        (bytes32 operationId, uint32 nonce) = accessManager.schedule(
            target,
            data,
            uint48(block.timestamp + TIMELOCK_24H)
        );

        // Verify operation is scheduled (operation ID should be non-zero)
        assertTrue(operationId != bytes32(0), "Operation should be scheduled");

        // ============================
        // Step 7: Guardian cancels the scheduled operation
        // ============================
        vm.prank(guardian);
        uint32 cancelNonce = accessManager.cancel(fuseManager, target, data);

        // Verify the cancel nonce matches the schedule nonce
        assertEq(nonce, cancelNonce, "Cancel nonce should match schedule nonce");

        // ============================
        // Step 8: Warp time past the timelock period
        // ============================
        vm.warp(block.timestamp + TIMELOCK_24H + 1);

        // ============================
        // Step 9: Try to execute the cancelled operation - should fail
        // ============================
        bytes memory expectedError = abi.encodeWithSignature("AccessManagerNotScheduled(bytes32)", operationId);

        vm.expectRevert(expectedError);
        vm.prank(fuseManager);
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fusesToAdd);

        // ============================
        // Step 10: Verify the fuse was NOT added
        // ============================
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(mockFuseToAdd),
            "Test fuse should NOT be supported after cancelled operation"
        );
    }

    /// @notice Additional test: Verify that without guardian cancel, the operation succeeds after timelock
    function testShouldAddFuseAfterTimelockWithoutCancel() public {
        // ============================
        // Step 1: Create vault using FusionFactory
        // ============================
        uint256 redemptionDelay = 1 seconds;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Test Vault 2",
            "TVAULT2",
            address(underlyingToken),
            redemptionDelay,
            owner
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        PlasmaVault plasmaVault = PlasmaVault(payable(instance.plasmaVault));

        // ============================
        // Step 2: Set 24h timelock for FUSE_MANAGER_ROLE
        // ============================
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = Roles.FUSE_MANAGER_ROLE;

        uint256[] memory delays = new uint256[](1);
        delays[0] = TIMELOCK_24H;

        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roleIds, delays);

        // ============================
        // Step 3: Grant roles
        // ============================
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, uint32(TIMELOCK_24H));
        vm.stopPrank();

        // ============================
        // Step 4: Verify test fuse is NOT yet supported
        // ============================
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(mockFuseToAdd),
            "Test fuse should NOT be supported initially"
        );

        // ============================
        // Step 5: FuseManager schedules adding the fuse
        // ============================
        address target = address(plasmaVault);
        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = mockFuseToAdd;
        bytes memory data = abi.encodeWithSelector(PlasmaVaultGovernance.addFuses.selector, fusesToAdd);

        vm.prank(fuseManager);
        accessManager.schedule(target, data, uint48(block.timestamp + TIMELOCK_24H));

        // ============================
        // Step 6: Warp time past the timelock period (without cancel)
        // ============================
        vm.warp(block.timestamp + TIMELOCK_24H + 1);

        // ============================
        // Step 7: Execute the operation - should succeed
        // ============================
        vm.prank(fuseManager);
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fusesToAdd);

        // ============================
        // Step 8: Verify the fuse WAS added
        // ============================
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(mockFuseToAdd),
            "Test fuse SHOULD be supported after timelock passed"
        );
    }

    /// @notice Test: Verify execution before timelock fails
    function testShouldFailExecutionBeforeTimelock() public {
        // ============================
        // Step 1: Create vault using FusionFactory
        // ============================
        uint256 redemptionDelay = 1 seconds;

        FusionFactoryLogicLib.FusionInstance memory instance = fusionFactory.create(
            "Test Vault 3",
            "TVAULT3",
            address(underlyingToken),
            redemptionDelay,
            owner
        );

        IporFusionAccessManager accessManager = IporFusionAccessManager(instance.accessManager);
        PlasmaVault plasmaVault = PlasmaVault(payable(instance.plasmaVault));

        // ============================
        // Step 2: Set 24h timelock for FUSE_MANAGER_ROLE
        // ============================
        uint64[] memory roleIds = new uint64[](1);
        roleIds[0] = Roles.FUSE_MANAGER_ROLE;

        uint256[] memory delays = new uint256[](1);
        delays[0] = TIMELOCK_24H;

        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roleIds, delays);

        // ============================
        // Step 3: Grant roles
        // ============================
        vm.startPrank(owner);
        accessManager.grantRole(Roles.ATOMIST_ROLE, owner, 0);
        accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, fuseManager, uint32(TIMELOCK_24H));
        vm.stopPrank();

        // ============================
        // Step 4: FuseManager schedules adding the fuse
        // ============================
        address target = address(plasmaVault);
        address[] memory fusesToAdd = new address[](1);
        fusesToAdd[0] = mockFuseToAdd;
        bytes memory data = abi.encodeWithSelector(PlasmaVaultGovernance.addFuses.selector, fusesToAdd);

        vm.prank(fuseManager);
        (bytes32 operationId, ) = accessManager.schedule(target, data, uint48(block.timestamp + TIMELOCK_24H));

        // ============================
        // Step 5: Try to execute BEFORE timelock passes - should fail
        // ============================
        vm.warp(block.timestamp + 1 hours); // Only 1 hour, not 24 hours

        bytes memory expectedError = abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId);

        vm.expectRevert(expectedError);
        vm.prank(fuseManager);
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fusesToAdd);

        // ============================
        // Step 6: Verify the fuse was NOT added
        // ============================
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(mockFuseToAdd),
            "Test fuse should NOT be supported before timelock"
        );
    }
}
