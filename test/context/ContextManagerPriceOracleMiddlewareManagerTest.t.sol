// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {PriceOracleMiddlewareManager} from "../../contracts/managers/price/PriceOracleMiddlewareManager.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {ContextManager} from "../../contracts/managers/context/ContextManager.sol";
import {ContextClient} from "../../contracts/managers/context/ContextClient.sol";
import {IContextClient} from "../../contracts/managers/context/IContextClient.sol";

contract ContextManagerPriceOracleMiddlewareManagerTest is Test {
    address private constant _DAO = address(1111111);
    address private constant _OWNER = address(2222222);
    address private constant _ADMIN = address(3333333);
    address private constant _ATOMIST = address(4444444);
    address private constant _ALPHA = address(5555555);
    address private constant _USER = address(6666666);
    address private constant _GUARDIAN = address(7777777);
    address private constant _FUSE_MANAGER = address(8888888);
    address private constant _CLAIM_REWARDS = address(7777777);
    address private constant _TRANSFER_REWARDS_MANAGER = address(8888888);
    address private constant _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER = address(9999999);

    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _PRICE_ORACLE_MIDDLEWARE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;

    IporFusionAccessManager private _accessManager;
    address private _withdrawManager;
    address private _plasmaVault;
    PriceOracleMiddlewareManager private _priceOracleMiddlewareManager;
    ContextManager private _contextManager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22238002);
        _deployMinimalPlasmaVault();
        _setupInitialRoles();
    }

    function testShouldHaveTechContextManagerRoleOnContextManager() public view {
        (bool hasRole, ) = _accessManager.hasRole(Roles.TECH_CONTEXT_MANAGER_ROLE, address(_contextManager));
        assertTrue(hasRole, "ContextManager should have TECH_CONTEXT_MANAGER_ROLE");
    }

    function testShouldAllowContextManagerToCallSetupContextOnPriceOracleMiddlewareManager() public {
        // given / when
        vm.prank(address(_contextManager));
        _priceOracleMiddlewareManager.setupContext(_ATOMIST);

        // then - no revert means success, verify context was set by clearing it
        vm.prank(address(_contextManager));
        _priceOracleMiddlewareManager.clearContext();
    }

    function testShouldAllowContextManagerToCallClearContextOnPriceOracleMiddlewareManager() public {
        // given - setup context first
        vm.prank(address(_contextManager));
        _priceOracleMiddlewareManager.setupContext(_ATOMIST);

        // when
        vm.prank(address(_contextManager));
        _priceOracleMiddlewareManager.clearContext();

        // then - no revert means success
    }

    function testShouldRevertWhenNonContextManagerCallsSetupContextOnPriceOracleMiddlewareManager() public {
        vm.prank(_USER);
        vm.expectRevert();
        _priceOracleMiddlewareManager.setupContext(_ATOMIST);
    }

    function testShouldRevertWhenNonContextManagerCallsClearContextOnPriceOracleMiddlewareManager() public {
        // setup context first
        vm.prank(address(_contextManager));
        _priceOracleMiddlewareManager.setupContext(_ATOMIST);

        vm.prank(_USER);
        vm.expectRevert();
        _priceOracleMiddlewareManager.clearContext();
    }

    function _deployMinimalPlasmaVault() private {
        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        _accessManager = new IporFusionAccessManager(_ATOMIST, 0);
        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        _priceOracleMiddlewareManager = new PriceOracleMiddlewareManager(
            address(_accessManager),
            _PRICE_ORACLE_MIDDLEWARE
        );

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "USDC Plasma Vault",
            assetSymbol: "USDC-PV",
            underlyingToken: _USDC,
            priceOracleMiddleware: address(_priceOracleMiddlewareManager),
            feeConfig: feeConfig,
            accessManager: address(_accessManager),
            plasmaVaultBase: address(new PlasmaVaultBase()),
            withdrawManager: _withdrawManager,
            plasmaVaultVotesPlugin: address(0)
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(initData);
        vm.stopPrank();
    }

    function _setupInitialRoles() private {
        address[] memory approvedAddresses = new address[](2);
        approvedAddresses[0] = _plasmaVault;
        approvedAddresses[1] = address(_priceOracleMiddlewareManager);
        _contextManager = new ContextManager(address(_accessManager), approvedAddresses);

        address[] memory daos = new address[](1);
        daos[0] = _DAO;

        address[] memory admins = new address[](1);
        admins[0] = _ADMIN;

        address[] memory owners = new address[](1);
        owners[0] = _OWNER;

        address[] memory atomists = new address[](1);
        atomists[0] = _ATOMIST;

        address[] memory alphas = new address[](1);
        alphas[0] = _ALPHA;

        address[] memory guardians = new address[](1);
        guardians[0] = _GUARDIAN;

        address[] memory fuseManagers = new address[](1);
        fuseManagers[0] = _FUSE_MANAGER;

        address[] memory claimRewards = new address[](1);
        claimRewards[0] = _CLAIM_REWARDS;

        address[] memory transferRewardsManagers = new address[](1);
        transferRewardsManagers[0] = _TRANSFER_REWARDS_MANAGER;

        address[] memory configInstantWithdrawalFusesManagers = new address[](1);
        configInstantWithdrawalFusesManagers[0] = _CONFIG_INSTANT_WITHDRAWAL_FUSES_MANAGER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: true,
            iporDaos: daos,
            admins: admins,
            owners: owners,
            atomists: atomists,
            alphas: alphas,
            whitelist: new address[](0),
            guardians: guardians,
            fuseManagers: fuseManagers,
            claimRewards: claimRewards,
            transferRewardsManagers: transferRewardsManagers,
            configInstantWithdrawalFusesManagers: configInstantWithdrawalFusesManagers,
            updateMarketsBalancesAccounts: new address[](0),
            updateRewardsBalanceAccounts: new address[](0),
            withdrawManagerRequestFeeManagers: new address[](0),
            withdrawManagerWithdrawFeeManagers: new address[](0),
            priceOracleMiddlewareManagers: new address[](0),
            preHooksManagers: new address[](0),
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: address(_accessManager),
                rewardsClaimManager: address(0x123),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(_contextManager),
                priceOracleMiddlewareManager: address(_priceOracleMiddlewareManager)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);

        vm.startPrank(_ATOMIST);
        _accessManager.initialize(initializationData);
        vm.stopPrank();
    }
}
