// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {PlasmaVault, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";

import {PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

contract InitializeAccessManagerTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    string public assetName = "IPOR Fusion DAI";
    string public assetSymbol = "ipfDAI";

    address public admin = address(0x1);
    address public initAlpha = address(0x2);
    address public performanceFeeManager = address(0x3);
    address public managementFeeManager = address(0x4);

    PriceOracleMiddleware public priceOracleMiddlewareProxy;
    IporFusionAccessManager public accessManager;

    PlasmaVault public plasmaVault;
    RewardsClaimManager public rewardsClaimManager;
    WithdrawManager public withdrawManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin)))
        );

        accessManager = new IporFusionAccessManager(admin, 0);
        withdrawManager = new WithdrawManager(address(accessManager));

        vm.startPrank(admin);
        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(accessManager),
                address(new PlasmaVaultBase()),
                address(withdrawManager)
            )
        );

        vm.stopPrank();

        rewardsClaimManager = new RewardsClaimManager(address(accessManager), address(plasmaVault));
    }

    function testShouldSetupAccessManager() public {
        //given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        for (uint256 i; i < initData.roleToFunctions.length; i++) {
            assertEq(
                accessManager.getTargetFunctionRole(
                    initData.roleToFunctions[i].target,
                    initData.roleToFunctions[i].functionSelector
                ),
                initData.roleToFunctions[i].roleId
            );
        }

        for (uint256 i; i < initData.accountToRoles.length; i++) {
            (bool isMember, uint32 executionDelay) = accessManager.hasRole(
                initData.accountToRoles[i].roleId,
                initData.accountToRoles[i].account
            );
            assertTrue(isMember);
            assertEq(executionDelay, initData.accountToRoles[i].executionDelay, "Execution delay should be set");
        }

        for (uint256 i; i < initData.adminRoles.length; i++) {
            assertEq(
                accessManager.getRoleAdmin(initData.adminRoles[i].roleId),
                initData.adminRoles[i].adminRoleId,
                "Admin role should be set"
            );
            if (
                initData.adminRoles[i].roleId != Roles.ADMIN_ROLE &&
                initData.adminRoles[i].roleId != Roles.GUARDIAN_ROLE &&
                initData.adminRoles[i].roleId != Roles.PUBLIC_ROLE &&
                initData.adminRoles[i].roleId != Roles.OWNER_ROLE &&
                initData.adminRoles[i].roleId != Roles.IPOR_DAO_ROLE &&
                initData.adminRoles[i].roleId != Roles.TECH_CONTEXT_MANAGER_ROLE &&
                initData.adminRoles[i].roleId != Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE &&
                initData.adminRoles[i].roleId != Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE &&
                initData.adminRoles[i].roleId != Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE
            ) {
                assertEq(
                    accessManager.getRoleGuardian(initData.adminRoles[i].roleId),
                    Roles.GUARDIAN_ROLE,
                    "Guardian role should be set"
                );
            }
        }

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 0, "Redemption delay should be 0");
    }

    function testShouldSetupAccessManagerWithoutRewardsClaimManager() public {
        //given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        for (uint256 i; i < initData.roleToFunctions.length; i++) {
            if (initData.roleToFunctions[i].target == address(0)) {
                continue;
            }
            assertEq(
                accessManager.getTargetFunctionRole(
                    initData.roleToFunctions[i].target,
                    initData.roleToFunctions[i].functionSelector
                ),
                initData.roleToFunctions[i].roleId
            );
        }

        for (uint256 i; i < initData.accountToRoles.length; i++) {
            (bool isMember, uint32 executionDelay) = accessManager.hasRole(
                initData.accountToRoles[i].roleId,
                initData.accountToRoles[i].account
            );
            assertTrue(isMember);
            assertEq(executionDelay, initData.accountToRoles[i].executionDelay);
        }

        for (uint256 i; i < initData.adminRoles.length; i++) {
            assertEq(
                accessManager.getRoleAdmin(initData.adminRoles[i].roleId),
                initData.adminRoles[i].adminRoleId,
                "Admin role should be set"
            );
            if (
                initData.adminRoles[i].roleId != Roles.ADMIN_ROLE &&
                initData.adminRoles[i].roleId != Roles.GUARDIAN_ROLE &&
                initData.adminRoles[i].roleId != Roles.PUBLIC_ROLE &&
                initData.adminRoles[i].roleId != Roles.CLAIM_REWARDS_ROLE &&
                initData.adminRoles[i].roleId != Roles.TRANSFER_REWARDS_ROLE &&
                initData.adminRoles[i].roleId != Roles.OWNER_ROLE &&
                initData.adminRoles[i].roleId != Roles.IPOR_DAO_ROLE &&
                initData.adminRoles[i].roleId != Roles.TECH_CONTEXT_MANAGER_ROLE &&
                initData.adminRoles[i].roleId != Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE &&
                initData.adminRoles[i].roleId != Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE &&
                initData.adminRoles[i].roleId != Roles.PRICE_ORACLE_MIDDLEWARE_MANAGER_ROLE
            ) {
                assertEq(
                    accessManager.getRoleGuardian(initData.adminRoles[i].roleId),
                    Roles.GUARDIAN_ROLE,
                    "Guardian role should be set"
                );
            }
        }

        assertEq(accessManager.REDEMPTION_DELAY_IN_SECONDS(), 0, "Redemption delay should be 0");
    }

    function testShouldNotBeAbleToCallInitializeTwiceWhenRevokeAdminRole() external {
        //given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", admin);
        // when
        vm.expectRevert(error);
        vm.prank(admin);
        accessManager.initialize(initData);
    }

    function testShouldNotBeAbleToCallInitializeTwice() external {
        //given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        bytes memory error = abi.encodeWithSignature("AlreadyInitialized()");
        // when
        vm.expectRevert(error);
        vm.prank(data.admins[0]);
        accessManager.initialize(initData);
    }

    function testShouldAtomistGrantWithdrawManagerWithdrawFeeRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address newWithdrawFeeManager = address(0x123);

        // when
        vm.prank(data.atomists[0]);
        accessManager.grantRole(Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE, newWithdrawFeeManager, 0);

        // then
        (bool isMember, uint32 executionDelay) = accessManager.hasRole(
            Roles.WITHDRAW_MANAGER_WITHDRAW_FEE_ROLE,
            newWithdrawFeeManager
        );
        assertTrue(isMember);
        assertEq(executionDelay, 0);
    }

    function testShouldAtomistGrantWithdrawManagerRequestFeeRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address newRequestFeeManager = address(0x456);

        // when
        vm.prank(data.atomists[0]);
        accessManager.grantRole(Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE, newRequestFeeManager, 0);

        // then
        (bool isMember, uint32 executionDelay) = accessManager.hasRole(
            Roles.WITHDRAW_MANAGER_REQUEST_FEE_ROLE,
            newRequestFeeManager
        );
        assertTrue(isMember);
        assertEq(executionDelay, 0);
    }

    function testShouldWithdrawManagerUpdateWithdrawFee() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address withdrawFeeManager = data.withdrawManagerWithdrawFeeManagers[0];
        uint256 newFee = 100; // 1%

        // when
        vm.prank(withdrawFeeManager);
        withdrawManager.updateWithdrawFee(newFee);

        // then
        assertEq(withdrawManager.getWithdrawFee(), newFee);
    }

    function testShouldWithdrawManagerUpdateRequestFee() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address requestFeeManager = data.withdrawManagerRequestFeeManagers[0];
        uint256 newFee = 50; // 0.5%

        // when
        vm.prank(requestFeeManager);
        withdrawManager.updateRequestFee(newFee);

        // then
        assertEq(withdrawManager.getRequestFee(), newFee);
    }

    function testShouldRevertWhenNonWithdrawManagerTriesToUpdateWithdrawFee() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address nonManager = address(0x789);
        uint256 newFee = 100;

        // when/then
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonManager);
        vm.expectRevert(error);
        vm.prank(nonManager);
        withdrawManager.updateWithdrawFee(newFee);
    }

    function testShouldRevertWhenNonRequestManagerTriesToUpdateRequestFee() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address nonManager = address(0x789);
        uint256 newFee = 50;

        // when/then
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", nonManager);
        vm.expectRevert(error);
        vm.prank(nonManager);
        withdrawManager.updateRequestFee(newFee);
    }

    function testShouldOwnersHaveOwnerAdminRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        for (uint256 i; i < data.owners.length; i++) {
            address owner = data.owners[i];

            // Check that owner has OWNER_ROLE
            (bool hasOwnerRole, uint32 ownerRoleDelay) = accessManager.hasRole(Roles.OWNER_ROLE, owner);
            assertTrue(hasOwnerRole, "Owner should have OWNER_ROLE");
            assertEq(ownerRoleDelay, 0, "OWNER_ROLE execution delay should be 0");
        }
    }

    function testShouldOwnersBeAbleToManageOwnerRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address newOwner = address(0x999);
        address owner = data.owners[0];

        // when - owner should be able to grant OWNER_ROLE to new address
        vm.prank(owner);
        accessManager.grantRole(Roles.OWNER_ROLE, newOwner, 0);

        // then
        (bool hasOwnerRole, uint32 executionDelay) = accessManager.hasRole(Roles.OWNER_ROLE, newOwner);
        assertTrue(hasOwnerRole, "New owner should have OWNER_ROLE");
        assertEq(executionDelay, 0, "Execution delay should be 0");
    }

    function testOwnerRoleHasAdminRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        uint64 ownerRoleAdmin = accessManager.getRoleAdmin(Roles.OWNER_ROLE);
        assertEq(ownerRoleAdmin, Roles.OWNER_ROLE, "OWNER_ROLE should be managed by OWNER_ROLE");
    }

    function testShouldOwnersBeAbleToRevokeOwnerRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address ownerToRevoke = data.owners[1]; // Use second owner
        address owner = data.owners[0]; // Use first owner

        // when - owner should be able to revoke OWNER_ROLE from another owner
        vm.prank(owner);
        accessManager.revokeRole(Roles.OWNER_ROLE, ownerToRevoke);

        // then
        (bool hasOwnerRole, uint32 executionDelay) = accessManager.hasRole(Roles.OWNER_ROLE, ownerToRevoke);
        assertFalse(hasOwnerRole, "Revoked owner should not have OWNER_ROLE");
        assertEq(executionDelay, 0, "Execution delay should be 0 for non-member");
    }

    function testShouldNonOwnersNotBeAbleToManageOwnerRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address newOwner = address(0x999);
        address nonOwner = data.atomists[0]; // Use atomist as non-owner

        // when/then - non-owner should not be able to grant OWNER_ROLE
        vm.expectRevert();
        vm.prank(nonOwner);
        accessManager.grantRole(Roles.OWNER_ROLE, newOwner, 0);
    }

    function testShouldOwnerAdminRoleBeAdminOfOwnerRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        uint64 ownerRoleAdmin = accessManager.getRoleAdmin(Roles.OWNER_ROLE);
        assertEq(ownerRoleAdmin, Roles.OWNER_ROLE, "OWNER_ROLE should be managed by OWNER_ROLE");
    }

    function testShouldAdminRoleBeOwnerRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        data.plasmaVaultAddress.withdrawManager = address(withdrawManager);
        data.plasmaVaultAddress.priceOracleMiddlewareManager = address(priceOracleMiddlewareProxy);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        // when
        vm.prank(admin);
        accessManager.initialize(initData);

        // then
        uint64 ownerRoleAdmin = accessManager.getRoleAdmin(Roles.OWNER_ROLE);
        assertEq(ownerRoleAdmin, Roles.OWNER_ROLE, "OWNER_ROLE should be managed by OWNER_ROLE");
    }

    function testShouldNotGrantOwnerBySuperAdminBecauseOnlyOwnerRoleHasAdminRole() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);
        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        address admin = data.admins[0];

        address newOwner = address(0x999);

        assertNotEq(admin, address(0), "Admin should not be 0");

        // when/then
        vm.expectRevert();
        vm.startPrank(admin);
        accessManager.grantRole(Roles.OWNER_ROLE, newOwner, 0);
        vm.stopPrank();
    }

    function testShouldFuseManagerUpdateCallbackHandler() external {
        // given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
        data.plasmaVaultAddress.rewardsClaimManager = address(rewardsClaimManager);

        InitializationData memory initData = IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(
            data
        );

        vm.prank(admin);
        accessManager.initialize(initData);

        // when
        uint64 roleId = accessManager.getTargetFunctionRole(
            address(plasmaVault),
            PlasmaVaultGovernance.updateCallbackHandler.selector
        );

        // then
        assertEq(Roles.FUSE_MANAGER_ROLE, roleId);
    }

    function _generateDataForInitialization() private returns (DataForInitialization memory) {
        DataForInitialization memory data;
        data.admins = _generateAddresses(10, 10);
        data.owners = _generateAddresses(100, 10);
        data.atomists = _generateAddresses(1_000, 10);
        data.alphas = _generateAddresses(10_000, 10);
        data.whitelist = _generateAddresses(100_000, 10);
        data.guardians = _generateAddresses(1_000_000, 10);
        data.fuseManagers = _generateAddresses(10_000_000, 10);
        data.claimRewards = _generateAddresses(10_000_000_000, 10);
        data.transferRewardsManagers = _generateAddresses(100_000_000_000, 10);
        data.configInstantWithdrawalFusesManagers = _generateAddresses(1_000_000_000_000, 10);
        data.updateMarketsBalancesAccounts = _generateAddresses(10_000_000_000_000, 10);
        data.updateRewardsBalanceAccounts = _generateAddresses(100_000_000_000_000, 10);
        data.withdrawManagerRequestFeeManagers = _generateAddresses(1_000_000_000_000_000, 10);
        data.withdrawManagerWithdrawFeeManagers = _generateAddresses(10_000_000_000_000_000, 10);

        /// @dev Dummy addresses as default values
        data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: address(0x123),
            accessManager: address(0x123),
            rewardsClaimManager: address(0x123),
            withdrawManager: address(0x123),
            feeManager: address(0x123),
            contextManager: address(0x123),
            priceOracleMiddlewareManager: address(0x123)
        });

        return data;
    }

    function _generateAddresses(uint256 startIndex, uint256 numberOfAddresses) private returns (address[] memory) {
        address[] memory addresses = new address[](numberOfAddresses);
        for (uint256 i; i < numberOfAddresses; i++) {
            addresses[i] = vm.rememberKey(startIndex + i);
        }
        return addresses;
    }
}
