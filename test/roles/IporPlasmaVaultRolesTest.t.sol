// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {DataForInitialization} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RewardsClaimManager} from "../../contracts/managers/rewards/RewardsClaimManager.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {IporFusionAccessManagerInitializerLibV1} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InstantWithdrawalFusesParamsStruct} from "../../contracts/libraries/PlasmaVaultLib.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";

import {PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

contract IporPlasmaVaultRolesTest is Test {
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant CHAINLINK_USDC = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;
    address public constant AAVE_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address public constant ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;
    address public constant AAVE_PRICE_ORACLE = 0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7;

    address private _deployer = vm.rememberKey(1);
    address private _priceOracleMiddlewareProxy;
    DataForInitialization private _data;
    PlasmaVault private _plasmaVault;
    IporFusionAccessManager private _accessManager;
    WithdrawManager private _withdrawManager;
    RewardsClaimManager private _rewardsClaimManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        _generateDataForInitialization();
        _setupPriceOracleMiddleware();
        _generatePlasmaVault();
    }

    function testShouldAtomistGrantMarketSubstrates() external {
        // given
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        //when
        vm.startPrank(_data.fuseManagers[0]);
        IPlasmaVaultGovernance(address(_plasmaVault)).grantMarketSubstrates(IporFusionMarkets.AAVE_V3, substrates);
        vm.stopPrank();

        //then
        assertEq(
            IPlasmaVaultGovernance(address(_plasmaVault)).getMarketSubstrates(IporFusionMarkets.AAVE_V3)[0],
            substrates[0],
            "Market substrates should be equal"
        );
    }

    function testDeployerShouldNotBeAdminAfterInitialization() external view {
        // then
        (bool isMember, ) = _accessManager.hasRole(Roles.ADMIN_ROLE, _deployer);
        assertFalse(isMember, "Deployer should not be an admin");
    }

    function testDeployerShouldNotBeAlphaAfterInitialization() external view {
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
        _accessManager.setRoleAdmin(Roles.TECH_PERFORMANCE_FEE_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.TECH_MANAGEMENT_FEE_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.CLAIM_REWARDS_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE, uint64(11111));

        vm.prank(_deployer);
        vm.expectRevert(error);
        _accessManager.setRoleAdmin(Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE, uint64(11111));

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

    function testShouldBeAbleToCancelScheduledOpByGuardianForAtomistRole() external {
        //given
        address user = vm.rememberKey(1234);

        vm.prank(_data.owners[0]);
        _accessManager.grantRole(Roles.ATOMIST_ROLE, user, 10000);

        address target = address(_plasmaVault);
        bytes memory data = abi.encodeWithSignature("setPriceOracleMiddleware(address)", 21, address(this));

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

    function testSetRewardsClaimManagerAddressCannotBeUsedAfterBootstraping() external view {
        // then
        uint64 roleId = _accessManager.getTargetFunctionRole(
            address(_plasmaVault),
            PlasmaVaultGovernance.setRewardsClaimManagerAddress.selector
        );
        (bool isMember, uint32 executionDelay) = _accessManager.hasRole(
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            address(_rewardsClaimManager)
        );

        assertEq(
            roleId,
            Roles.TECH_REWARDS_CLAIM_MANAGER_ROLE,
            "Role id should be equal to rewards claim manager role"
        );
        assertTrue(isMember, "Rewards claim manager should be a member of rewards claim manager role");
        assertEq(executionDelay, 0, "Execution delay should be 0");
    }

    function testShouldReturnAccessManagerAsAuthority() external view {
        // then
        assertEq(_plasmaVault.authority(), address(_accessManager), "Access manager should be an authority");
        assertEq(_rewardsClaimManager.authority(), address(_accessManager), "Access manager should be an authority");
    }

    function testShouldSetupTotalSupplyCapByAtomist() external {
        // given
        uint256 totalSupplyCap = 1000;

        // when
        vm.prank(_data.atomists[0]);
        IPlasmaVaultGovernance(address(_plasmaVault)).setTotalSupplyCap(totalSupplyCap);

        // then
        assertEq(
            IPlasmaVaultGovernance(address(_plasmaVault)).getTotalSupplyCap(),
            totalSupplyCap,
            "Total supply cap should be set"
        );
    }

    function testShouldBeAbleToUpdateRewardsBalance() external {
        // when
        vm.prank(_data.updateRewardsBalanceAccounts[0]);
        RewardsClaimManager(_rewardsClaimManager).updateBalance();

        // then
        assertEq(RewardsClaimManager(_rewardsClaimManager).balanceOf(), 0, "Balance should be 0");
    }

    function testShouldBeAbleToUpdateRewardsBalanceSecondUser() external {
        // when
        vm.prank(_data.updateRewardsBalanceAccounts[1]);
        RewardsClaimManager(_rewardsClaimManager).updateBalance();

        // then
        assertEq(RewardsClaimManager(_rewardsClaimManager).balanceOf(), 0, "Balance should be 0");
    }

    function testShouldNotBeAbleToUpdateRewardsBalanceByNonUpdateRewardsBalanceAccount() external {
        // given
        address user = vm.rememberKey(1234);
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", user);

        // then
        vm.expectRevert(error);
        // when
        vm.prank(user);
        RewardsClaimManager(_rewardsClaimManager).updateBalance();
    }

    function testShouldBeAbleToUpdateMarketsBalances() external {
        // given
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = 0;

        // when
        vm.prank(_data.updateMarketsBalancesAccounts[0]);
        _plasmaVault.updateMarketsBalances(marketIds);

        // then
        assertEq(_plasmaVault.totalAssets(), 0, "Total assets should be 0");
    }

    function testShouldNotBeAbleToUpdateMarketsBalancesByNonUpdateMarketsBalancesAccount() external {
        // given
        address user = vm.rememberKey(1234);
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = 0;

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", user);

        // then
        vm.expectRevert(error);
        // when
        vm.prank(user);
        _plasmaVault.updateMarketsBalances(marketIds);
    }

    function testShouldAtomistBeAbleToGrantRoleUpdateRewardsBalance() external {
        // given
        address user = vm.rememberKey(1234);

        // when
        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, user, 10000);

        // then
        (bool isMember, uint32 executionDelay) = _accessManager.hasRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, user);
        assertEq(isMember, true, "User should have update rewards balance role");
        assertEq(executionDelay, 10000, "Execution delay should be 10000");
    }

    function testShouldNotBeAbleToGrantRoleUpdateRewardsBalanceByNonAtomist() external {
        // given
        address user = vm.rememberKey(1234);

        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            user,
            Roles.ATOMIST_ROLE
        );

        // when
        vm.prank(user);
        vm.expectRevert(error);
        _accessManager.grantRole(Roles.UPDATE_REWARDS_BALANCE_ROLE, user, 10000);
    }

    function testShouldAtomistBeAbleToGrantRoleUpdateMarketsBalances() external {
        // given
        address user = vm.rememberKey(1234);

        // when
        vm.prank(_data.atomists[0]);
        _accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, user, 10000);

        // then
        (bool isMember, uint32 executionDelay) = _accessManager.hasRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, user);
        assertEq(isMember, true, "User should have update markets balances role");
        assertEq(executionDelay, 10000, "Execution delay should be 10000");
    }

    function testShouldNotBeAbleToGrantRoleUpdateMarketsBalancesByNonAtomist() external {
        // given
        address user = vm.rememberKey(1234);

        bytes memory error = abi.encodeWithSignature(
            "AccessManagerUnauthorizedAccount(address,uint64)",
            user,
            Roles.ATOMIST_ROLE
        );

        // when
        vm.prank(user);
        vm.expectRevert(error);
        _accessManager.grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, user, 10000);
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
        _data.claimRewards = new address[](1);
        _data.claimRewards[0] = vm.rememberKey(10);
        _data.transferRewardsManagers = new address[](1);
        _data.transferRewardsManagers[0] = vm.rememberKey(11);
        _data.configInstantWithdrawalFusesManagers = new address[](1);
        _data.configInstantWithdrawalFusesManagers[0] = vm.rememberKey(12);
        _data.updateMarketsBalancesAccounts = new address[](1);
        _data.updateMarketsBalancesAccounts[0] = vm.rememberKey(13);
        _data.updateRewardsBalanceAccounts = new address[](2);
        _data.updateRewardsBalanceAccounts[0] = vm.rememberKey(14);
        _data.updateRewardsBalanceAccounts[1] = vm.rememberKey(15);
        _data.plasmaVaultAddress = PlasmaVaultAddress({
            plasmaVault: address(0x123),
            accessManager: address(0x123),
            rewardsClaimManager: address(0x123),
            withdrawManager: address(0x123),
            feeManager: address(0x123),
            contextManager: address(0x123),
            priceOracleMiddlewareManager: address(0x123)
        });
    }

    function _setupPriceOracleMiddleware() private {
        vm.startPrank(_data.owners[0]);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));

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
        marketConfigs[0] = MarketSubstratesConfig(IporFusionMarkets.AAVE_V3, assets);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            IporFusionMarkets.AAVE_V3,
            ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            IporFusionMarkets.AAVE_V3,
            ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER
        );

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(IporFusionMarkets.AAVE_V3, address(balanceFuse));
        _accessManager = new IporFusionAccessManager(_deployer, 0);
        _withdrawManager = new WithdrawManager(address(_accessManager));
        _plasmaVault = new PlasmaVault();
        PlasmaVault(_plasmaVault).proxyInitialize(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(_priceOracleMiddlewareProxy),
                FeeConfigHelper.createZeroFeeConfig(),
                address(_accessManager),
                address(new PlasmaVaultBase()),
                address(_withdrawManager)
            )
        );
        vm.stopPrank();
        _generateRewardsClaimManager();

        _initializeAccessManager();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _data.fuseManagers[0],
            address(_plasmaVault),
            fuses,
            balanceFuses,
            marketConfigs
        );
    }

    function _generateRewardsClaimManager() private {
        _rewardsClaimManager = new RewardsClaimManager(address(_accessManager), address(_plasmaVault));
        vm.prank(_deployer);
        IPlasmaVaultGovernance(address(_plasmaVault)).setRewardsClaimManagerAddress(address(_rewardsClaimManager));
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
