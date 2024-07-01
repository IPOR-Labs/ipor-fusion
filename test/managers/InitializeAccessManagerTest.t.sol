// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManager} from "../../contracts/managers/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/RewardsClaimManager.sol";
import {PlasmaVault, MarketSubstratesConfig, FeeConfig, MarketBalanceFuseConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/IporFusionAccessManagerInitializationLib.sol";
import {IporFusionRoles} from "../../contracts/libraries/IporFusionRoles.sol";

contract InitializeAccessManagerTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
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

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin)))
        );

        accessManager = new IporFusionAccessManager(admin);

        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(performanceFeeManager, 0, managementFeeManager, 0),
                address(accessManager)
            )
        );

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
            assertEq(executionDelay, initData.accountToRoles[i].executionDelay);
        }

        for (uint256 i; i < initData.adminRoles.length; i++) {
            assertEq(accessManager.getRoleAdmin(initData.adminRoles[i].roleId), initData.adminRoles[i].adminRoleId);
            if (
                initData.adminRoles[i].roleId != IporFusionRoles.ADMIN_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.GUARDIAN_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.PUBLIC_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.OWNER_ROLE
            ) {
                assertEq(accessManager.getRoleGuardian(initData.adminRoles[i].roleId), IporFusionRoles.GUARDIAN_ROLE);
            }
        }

        assertEq(accessManager.getRedemptionDelay(), 0);
    }

    function testShouldSetupAccessManagerWithoutRewardsClaimManager() public {
        //given
        DataForInitialization memory data = _generateDataForInitialization();
        data.plasmaVaultAddress.plasmaVault = address(plasmaVault);
        data.plasmaVaultAddress.accessManager = address(accessManager);
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
            assertEq(accessManager.getRoleAdmin(initData.adminRoles[i].roleId), initData.adminRoles[i].adminRoleId);
            if (
                initData.adminRoles[i].roleId != IporFusionRoles.ADMIN_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.GUARDIAN_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.PUBLIC_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.CLAIM_REWARDS_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.TRANSFER_REWARDS_ROLE &&
                initData.adminRoles[i].roleId != IporFusionRoles.OWNER_ROLE
            ) {
                assertEq(accessManager.getRoleGuardian(initData.adminRoles[i].roleId), IporFusionRoles.GUARDIAN_ROLE);
            }
        }

        assertEq(accessManager.getRedemptionDelay(), 0);
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

    function _generateDataForInitialization() private returns (DataForInitialization memory) {
        DataForInitialization memory data;
        data.admins = _generateAddresses(10, 10);
        data.owners = _generateAddresses(100, 10);
        data.atomists = _generateAddresses(1_000, 10);
        data.alphas = _generateAddresses(10_000, 10);
        data.whitelist = _generateAddresses(100_000, 10);
        data.guardians = _generateAddresses(1_000_000, 10);
        data.fuseManagers = _generateAddresses(10_000_000, 10);
        data.performanceFeeManagers = _generateAddresses(100_000_000, 10);
        data.managementFeeManagers = _generateAddresses(1_000_000_000, 10);
        data.claimRewards = _generateAddresses(10_000_000_000, 10);
        data.transferRewardsManagers = _generateAddresses(100_000_000_000, 10);
        data.configInstantWithdrawalFusesManagers = _generateAddresses(1_000_000_000_000, 10);

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
