// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {DataForInitialization} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionMarketsArbitrum} from "../../contracts/libraries/IporFusionMarketsArbitrum.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultFusionMock} from "../mocks/PlasmaVaultFusionMock.sol";

contract IporPlasmaVaultRolesTest is Test {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant AAVE_POOL_DATA_PROVIDER = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    address private _deployer = vm.rememberKey(1);
    address private _priceOracleMiddlewareProxy;
    DataForInitialization private _data;
    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    RewardsClaimManager private _rewardsClaimManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        _generateDataForInitialization();
        _setupPriceOracleMiddleware();
        _generatePlasmaVault();
        _generateRewardsClaimManager();
        _initializeAccessManager();
    }

    function testDeployerShouldNotBeAdminAfterInitialization() external {
        // then
        (bool isMember, ) = _accessManager.hasRole(Roles.ADMIN_ROLE, _deployer);
        assertFalse(isMember, "Deployer should not be an admin");
    }

    function testDeployerShouldNotBeAlphaAfterInitialization() external {
        // then
        (bool isMember, ) = _accessManager.hasRole(Roles.ALPHA_ROLE, _deployer);
        assertFalse(isMember, "Deployer should not be an alpha");
    }

    function testDeployerShouldNotBeAbleToSetRoleAdmin() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        // when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.ADMIN_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.OWNER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.GUARDIAN_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.ATOMIST_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.ALPHA_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.FUSE_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.PERFORMANCE_FEE_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.MANAGEMENT_FEE_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.CLAIM_REWARDS_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.REWARDS_CLAIM_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.REWARDS_CLAIM_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.TRANSFER_REWARDS_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.WHITELIST_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, uint64(11111));
    }

    function testShouldNotBeAbleToSetRoleGuardianByDeployer() external {
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleGuardian(Roles.ADMIN_ROLE, Roles.GUARDIAN_ROLE);
    }

    function testShouldNotBeAbleToSetTargetAdminDelayByDeployer() external {
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setTargetAdminDelay(address(_plasmaVault), 1000);
    }

    function testShouldNotBeAbleToUpdateTargetClosedByDeployer() external {
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _deployer);

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.updateTargetClosed(address(_plasmaVault), true);
    }

    function testShouldBeAbleToUpdateTargetClosedByGuardian() external {
        //given
        bool isCloseBefore = _accessManager.isTargetClosed(address(_plasmaVault));

        //when
        vm.prank(_data.guardians[0]);
        _accessManager.updateTargetClosed(address(_plasmaVault), true);

        //then
        bool isCloseAfter = _accessManager.isTargetClosed(address(_plasmaVault));

        assertFalse(isCloseBefore, "Before update target should be open");
        assertTrue(isCloseAfter, "After update target should be closed");
    }

    function testShouldNotBeAbleToUpdateAuthorityByDeployer() external {
        //given
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        address authorityBefore = _plasmaVault.authority();

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.updateAuthority(address(_plasmaVault), address(this));

        //then

        address authorityAfter = _plasmaVault.authority();

        assertEq(authorityBefore, authorityAfter, "Authority should not be changed");
        assertEq(authorityBefore, address(_accessManager), "Authority should be equal to access manager");
    }

    function testShouldNotBeAbleToSetTargetFunctionRoleByDeployer() external {
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector;

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setTargetFunctionRole(address(_plasmaVault), selectors, uint64(11111));
    }

    function testShouldNotBeAbleToSetTargetClosedByDeployer() external {
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector;

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setTargetClosed(address(_plasmaVault), true);
    }

    function testShouldNotBeAbleToLabelRoleByDeployer() external {
        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            _deployer,
            Roles.ADMIN_ROLE
        );

        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector;

        //when
        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.labelRole(Roles.ADMIN_ROLE, "ADMIN_ROLE");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForManagementFeeManagerRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.managementFeeManagers[0]);
        _accessManager.grantRole(Roles.MANAGEMENT_FEE_MANAGER_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("configureManagementFee(address,uint256)", address(0x555), 55);

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForPerformanceFeeManagerRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.performanceFeeManagers[0]);
        _accessManager.grantRole(Roles.PERFORMANCE_FEE_MANAGER_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("configurePerformanceFee(address,uint256)", address(0x555), 55);

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForAtomistRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.owners[0]);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("setPriceOracle(address)", 21, address(this));

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForAlphaRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.ALPHA_ROLE, user, 10000);
        FuseAction[] memory calls = new FuseAction[](0);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("execute((address,bytes)[])", calls);

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForFuseManagerRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.FUSE_MANAGER_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("addBalanceFuse(uint256,address)", 12, address(this));

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForClaimRewardsRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.CLAIM_REWARDS_ROLE, user, 10000);
        FuseAction[] memory calls = new FuseAction[](0);

        address target = address(_rewardsClaimManager);
        bytes memory data = abi.encodeWithSignature("claimRewards((address,bytes)[])", calls);

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForTransferRewardsRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.TRANSFER_REWARDS_ROLE, user, 10000);

        address target = address(_rewardsClaimManager);
        bytes memory data = abi.encodeWithSignature(
            "transfer(address,address,uint256)",
            address(this),
            address(this),
            100
        );

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForWhitelistRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.WHITELIST_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("deposit(uint256,address)", 1e18, address(this));

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testShouldBeAbleToCancelScheduledOpByGuardianForConfigInstantWithdrawalFusesRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.CONFIG_INSTANT_WITHDRAWAL_FUSES_ROLE, user, 10000);

        InstantWithdrawalFusesParamsStruct[] memory fuses = new InstantWithdrawalFusesParamsStruct[](0);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("configureInstantWithdrawalFuses((address,bytes32[])[])", fuses);

        vm.prank(user);
        (, uint32 nonceSchedule) = _accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        //when
        vm.prank(_data.guardians[0]);
        uint32 nonceCancel = _accessManager.cancel(user, target, data);

        //then
        assertEq(nonceSchedule, nonceCancel, "Nonce should be equal");
    }

    function testSetRewardsClaimManagerAddressCannotBeUsedAfterBootstraping() external {
        // then
        uint64 roleId = _accessManager.getTargetFunctionRole(
            address(_plasmaVault),
            PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector
        );
        (bool isMember, uint32 executionDelay) = _accessManager.hasRole(
            Roles.REWARDS_CLAIM_MANAGER_ROLE,
            address(_rewardsClaimManager)
        );

        assertEq(roleId, Roles.REWARDS_CLAIM_MANAGER_ROLE, "Role id should be equal to rewards claim manager role");
        assertTrue(isMember, "Rewards claim manager should be a member of rewards claim manager role");
        assertEq(executionDelay, 0, "Execution delay should be 0");
    }

    function testShouldReturnAccessManagerAsAuthority() external {
        // then
        assertEq(_plasmaVault.authority(), address(_accessManager), "Access manager should be an authority");
        assertEq(_rewardsClaimManager.authority(), address(_accessManager), "Access manager should be an authority");
    }

    function _generateDataForInitialization() private {
        _data.admins = new address[](0);
        _data.owners = new address[](1);
        _data.owners[0] = vm.rememberKey(2);
        _data.atomists = new address[](1);
        _data.atomists[0] = vm.rememberKey(3);
        _data.alphas = new address[](1);
        _data.alphas[0] = vm.rememberKey(4);
        _data.whitelist = new address[](1);
        _data.whitelist[0] = vm.rememberKey(5);
        _data.guardians = new address[](1);
        _data.guardians[0] = vm.rememberKey(6);
        _data.fuseManagers = new address[](1);
        _data.fuseManagers[0] = vm.rememberKey(7);
        _data.performanceFeeManagers = new address[](1);
        _data.performanceFeeManagers[0] = vm.rememberKey(8);
        _data.managementFeeManagers = new address[](1);
        _data.managementFeeManagers[0] = vm.rememberKey(9);
        _data.claimRewards = new address[](1);
        _data.claimRewards[0] = vm.rememberKey(10);
        _data.transferRewardsManagers = new address[](1);
        _data.transferRewardsManagers[0] = vm.rememberKey(11);
        _data.configInstantWithdrawalFusesManagers = new address[](1);
        _data.configInstantWithdrawalFusesManagers[0] = vm.rememberKey(12);
    }

    function _setupPriceOracleMiddleware() private {
        vm.startPrank(_data.owners[0]);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            address(0)
        );

        _priceOracleMiddlewareProxy = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", _data.owners[0]))
        );

        address[] memory assets = new address[](1);
        assets[0] = USDC;
        address[] memory sources = new address[](1);
        sources[0] = CHAINLINK_USDC;

        PriceOracleMiddleware(_priceOracleMiddlewareProxy).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function _generatePlasmaVault() private {
        string memory assetName = "IPOR Fusion ";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        vm.startPrank(_deployer);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarketsArbitrum.AAVE_V3, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_PRICE_ORACLE,
            AAVE_POOL_DATA_PROVIDER
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            IporFusionMarketsArbitrum.AAVE_V3,
            AAVE_POOL,
            AAVE_POOL_DATA_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarketsArbitrum.AAVE_V3, address(balanceFuse));
        _accessManager = new IporFusionAccessManager(_deployer);

        _plasmaVault = new PlasmaVaultFusionMock(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(_priceOracleMiddlewareProxy),
                _data.alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(_data.performanceFeeManagers[0], 0, _data.managementFeeManagers[0], 0),
                address(_accessManager)
            )
        );
        vm.stopPrank();
    }

    function _generateRewardsClaimManager() private {
        _rewardsClaimManager = new RewardsClaimManager(address(_accessManager), address(_plasmaVault));
        vm.prank(_deployer);
        _plasmaVault.setRewardsClaimManagerAddress(address(_rewardsClaimManager));
    }

    function _initializeAccessManager() private {
        _data.plasmaVaultAddress.plasmaVault = address(_plasmaVault);
        _data.plasmaVaultAddress.accessManager = address(_accessManager);
        _data.plasmaVaultAddress.rewardsClaimManager = address(_rewardsClaimManager);

        vm.startPrank(_deployer);
        _accessManager.initialize(IporFusionAccessManagerInitializerLibV1.generateInitializeIporPlasmaVault(_data));
        vm.stopPrank();
    }
}