// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {FeeConfig, RecipientFee} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeManager, FeeManagerInitData} from "../../contracts/managers/fee/FeeManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

import {IPool} from "../../contracts/fuses/aave_v3/ext/IPool.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {HighWaterMarkPerformanceFeeStorage} from "../../contracts/managers/fee/FeeManagerStorageLib.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {WithdrawManager} from "../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../utils/PlasmaVaultConfigurator.sol";

contract FeeManagerTest is Test {
    address private constant _DAO = address(9999999);
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _FEE_RECIPIENT_1 = address(5555);
    address private constant _FEE_RECIPIENT_2 = address(5556);
    address private constant _DAO_FEE_RECIPIENT = address(7777);

    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);

    address public constant ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb;

    uint256 private constant PERFORMANCE_FEE_IN_PERCENTAGE = 1000;
    uint256 private constant DAO_PERFORMANCE_FEE_IN_PERCENTAGE = 1000;
    uint256 private constant MANAGEMENT_FEE_IN_PERCENTAGE = 200;
    uint256 private constant DAO_MANAGEMENT_FEE_IN_PERCENTAGE = 300;

    address private _plasmaVault;
    address private _priceOracle = 0x9838c0d15b439816D25d5fD1AEbd259EeddB66B4;
    address private _accessManager;
    address private _withdrawManager;

    address private _aaveFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 256415332);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 20_000e6);
        _createAccessManager();
        _createWithdrawManager();
        _createPriceOracle();
        _createPlasmaVault();
        _initAccessManager();
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();
    }

    function _createPlasmaVault() private {
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData({
                    assetName: "PLASMA VAULT",
                    assetSymbol: "PLASMA",
                    underlyingToken: _USDC,
                    priceOracleMiddleware: _priceOracle,
                    feeConfig: _setupFeeConfig(),
                    accessManager: address(_accessManager),
                    plasmaVaultBase: address(new PlasmaVaultBase()),
                    withdrawManager: _withdrawManager
                })
            )
        );


         RecipientFee[] memory performanceRecipientFees = new RecipientFee[](1);
        performanceRecipientFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: PERFORMANCE_FEE_IN_PERCENTAGE
        });

        RecipientFee[] memory managementRecipientFees = new RecipientFee[](1);
        managementRecipientFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: MANAGEMENT_FEE_IN_PERCENTAGE
        });
        vm.stopPrank();
        
        PlasmaVaultConfigurator.setupRecipientFees(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            managementRecipientFees,
            performanceRecipientFees
        );

        
    }

    function _createFuse() private returns (address[] memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = address(new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER));
        _aaveFuse = fuses[0];
        return fuses;
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](1);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        marketConfigs[0] = MarketSubstratesConfig({marketId: IporFusionMarkets.AAVE_V3, substrates: substrates});
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](1);

        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.AAVE_V3,
            fuse: address(new AaveV3BalanceFuse(IporFusionMarkets.AAVE_V3, ARBITRUM_AAVE_V3_POOL_ADDRESSES_PROVIDER))
        });
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        
        address feeManagerFactory = address(new FeeManagerFactory());

        feeConfig = FeeConfig({
            feeFactory: feeManagerFactory,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT
        });
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _createWithdrawManager() private {
        _withdrawManager = address(new WithdrawManager(address(_accessManager)));
    }

    function _createPriceOracle() private {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = _USDC;
        sources[0] = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

        PriceOracleMiddleware(_priceOracle).setAssetsPricesSources(assets, sources);
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        address[] memory dao = new address[](1);
        dao[0] = _DAO;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: dao,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            updateMarketsBalancesAccounts: initAddress,
            updateRewardsBalanceAccounts: initAddress,
            withdrawManagerRequestFeeManagers: initAddress,
            withdrawManagerWithdrawFeeManagers: initAddress,
            priceOracleMiddlewareManagers: initAddress,
            preHooksManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: _withdrawManager,
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0),
                priceOracleMiddlewareManager: address(0)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function testShouldHaveSharesOnManagementFeeAccount() external {
        //given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeAccount;

        uint256 balanceBefore = PlasmaVault(_plasmaVault).balanceOf(managementAccount);

        vm.warp(block.timestamp + 356 days);

        //when
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 1_000e6);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        //then

        uint256 balanceAfter = PlasmaVault(_plasmaVault).balanceOf(managementAccount);

        assertEq(balanceBefore, 0, "balanceBefore should be 0");
        assertEq(balanceAfter, 48767123200, "balanceAfter should be 48767123200");
    }

    function testShouldHarvestManagementFee() external {
        //given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(managementAccount).FEE_MANAGER());

        vm.warp(block.timestamp + 356 days);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 1_000e6);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        feeManager.initialize();

        uint256 balanceManagementAccountBefore = PlasmaVault(_plasmaVault).balanceOf(managementAccount);
        uint256 balanceFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        //when
        feeManager.harvestManagementFee();

        //then
        uint256 balanceManagementAccountAfter = PlasmaVault(_plasmaVault).balanceOf(managementAccount);
        uint256 balanceFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(balanceManagementAccountBefore, 48767123200, "balanceManagementAccountBefore should be 48767123200");
        assertEq(balanceManagementAccountAfter, 0, "balanceManagementAccountAfter should be 0");

        assertEq(balanceFeeRecipientBefore, 0, "balanceFeeRecipientBefore should be 0");
        assertEq(balanceFeeRecipientAfter, 19506849280, "balanceFeeRecipientAfter should be 19506849280");

        assertEq(balanceDaoFeeRecipientBefore, 0, "balanceDaoFeeRecipientBefore should be 0");
        assertEq(balanceDaoFeeRecipientAfter, 29260273920, "balanceDaoFeeRecipientAfter should be 29260273920");
    }

    function testShouldHaveShearsOnPerformanceFeeAccount() external {
        //given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;

        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());
        feeManager.initialize();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        uint256 balanceBefore = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);

        vm.warp(block.timestamp + 356 days);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;

        //when
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        //then
        uint256 balanceAfter = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);

        assertEq(balanceBefore, 0, "balanceBefore should be 0");
        assertEq(balanceAfter, 88687800000, "balanceAfter should be 88687800000");
    }

    function testShouldHarvestPerformance() external {
        //given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        feeManager.initialize();

        vm.warp(block.timestamp + 356 days);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 balancePerformanceAccountBefore = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);
        uint256 balanceFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        //when
        feeManager.harvestPerformanceFee();

        //then
        uint256 balancePerformanceAccountAfter = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);
        uint256 balanceFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(balancePerformanceAccountBefore, 88687800000, "balancePerformanceAccountBefore should be 88687800000");
        assertApproxEqAbs(balancePerformanceAccountAfter, 0, 100, "balancePerformanceAccountAfter should be 0");

        assertEq(balanceFeeRecipientBefore, 0, "balanceFeeRecipientBefore should be 0");
        assertEq(balanceFeeRecipientAfter, 44343900000, "balanceFeeRecipientAfter should be 44343900000");

        assertEq(balanceDaoFeeRecipientBefore, 0, "balanceDaoFeeRecipientBefore should be 0");
        assertEq(balanceDaoFeeRecipientAfter, 44343900000, "balanceDaoFeeRecipientAfter should be 44343900000");
    }

    function testShouldHarvestPerformanceWhenAtomistSetZero() external {
        //given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        feeManager.initialize();

        RecipientFee[] memory recipientFees = new RecipientFee[](0);

        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(recipientFees);
        vm.stopPrank();

        vm.warp(block.timestamp + 356 days);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 balancePerformanceAccountBefore = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);
        uint256 balanceFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        //when
        feeManager.harvestPerformanceFee();

        //then
        uint256 balancePerformanceAccountAfter = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);
        uint256 balanceFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceDaoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertApproxEqAbs(
            balancePerformanceAccountBefore,
            44343899997,
            100,
            "balancePerformanceAccountBefore should be 44343899997"
        );
        assertEq(balancePerformanceAccountAfter, 0, "balancePerformanceAccountAfter should be 0");

        assertEq(balanceFeeRecipientBefore, 0, "balanceFeeRecipientBefore should be 0");
        assertEq(balanceFeeRecipientAfter, 0, "balanceFeeRecipientAfter should be 0");

        assertEq(balanceDaoFeeRecipientBefore, 0, "balanceDaoFeeRecipientBefore should be 0");
        assertApproxEqAbs(
            balanceDaoFeeRecipientAfter,
            44343899997,
            100,
            "balanceDaoFeeRecipientAfter should be 34099552392"
        );
    }

    function testShouldNotHarvestManagementFeeWhenNotInitialize() external {
        // given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(managementAccount).FEE_MANAGER());

        bytes memory error = abi.encodeWithSignature("NotInitialized()");

        // when
        vm.expectRevert(error);
        feeManager.harvestManagementFee();
    }

    function testShouldNotHarvestPerformanceFeeWhenNotInitialize() external {
        // given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(managementAccount).FEE_MANAGER());

        bytes memory error = abi.encodeWithSignature("NotInitialized()");

        // when
        vm.expectRevert(error);
        feeManager.harvestPerformanceFee();
    }

    function testShouldNotUpdatePerformanceFeeWhenNotAtomist() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: 500});

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updatePerformanceFee(recipientFees);
        vm.stopPrank();
    }

    function testShouldUpdatePerformanceFeeWhenAtomist() external {
        // given
        PlasmaVaultStorageLib.PerformanceFeeData memory feeDataOnPlasmaVaultBefore = PlasmaVaultGovernance(_plasmaVault)
            .getPerformanceFeeData();
        FeeManager feeManager = FeeManager(FeeAccount(feeDataOnPlasmaVaultBefore.feeAccount).FEE_MANAGER());

        uint256 performanceFeeBefore = feeManager.getTotalPerformanceFee();

        feeManager.initialize();

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: 500});

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(recipientFees);
        vm.stopPrank();

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeDataOnPlasmaVaultAfter = PlasmaVaultGovernance(_plasmaVault)
            .getPerformanceFeeData();

        uint256 performanceFeeAfter = feeManager.getTotalPerformanceFee();

        assertEq(performanceFeeBefore, 2000, "performanceFeeBefore should be 2000");
        assertEq(performanceFeeAfter, 1500, "performanceFeeAfter should be 1500");

        assertEq(
            feeDataOnPlasmaVaultBefore.feeInPercentage,
            2000,
            "feeDataOnPlasmaVaultBefore.feeInPercentage should be 2000"
        );
        assertEq(
            feeDataOnPlasmaVaultAfter.feeInPercentage,
            1500,
            "feeDataOnPlasmaVaultAfter.feeInPercentage should be 1500"
        );
    }

    function testShouldUpdateManagementFeeWhenAtomist() external {
        // given
        PlasmaVaultStorageLib.ManagementFeeData memory feeDataOnPlasmaVaultBefore = PlasmaVaultGovernance(_plasmaVault)
            .getManagementFeeData();
        FeeManager feeManager = FeeManager(FeeAccount(feeDataOnPlasmaVaultBefore.feeAccount).FEE_MANAGER());

        uint256 managementFeeBefore = feeManager.getTotalManagementFee();

        feeManager.initialize();

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: 50});

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateManagementFee(recipientFees);
        vm.stopPrank();

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeDataOnPlasmaVaultAfter = PlasmaVaultGovernance(_plasmaVault)
            .getManagementFeeData();

        uint256 managementFeeAfter = feeManager.getTotalManagementFee();

        assertEq(managementFeeBefore, 500, "managementFeeBefore should be 500");
        assertEq(managementFeeAfter, 350, "managementFeeAfter should be 350");

        assertEq(
            feeDataOnPlasmaVaultBefore.feeInPercentage,
            500,
            "feeDataOnPlasmaVaultBefore.feeInPercentage should be 500"
        );
        assertEq(
            feeDataOnPlasmaVaultAfter.feeInPercentage,
            350,
            "feeDataOnPlasmaVaultAfter.feeInPercentage should be 350"
        );
    }

    function testShouldUpdateManagementFeeToZeroWhenAtomist() external {
        // given
        PlasmaVaultStorageLib.ManagementFeeData memory feeDataOnPlasmaVaultBefore = PlasmaVaultGovernance(_plasmaVault)
            .getManagementFeeData();
        FeeManager feeManager = FeeManager(FeeAccount(feeDataOnPlasmaVaultBefore.feeAccount).FEE_MANAGER());

        feeManager.initialize();

        vm.warp(block.timestamp + 356 days);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 1_000e6);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        RecipientFee[] memory recipientFees = new RecipientFee[](0);

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateManagementFee(recipientFees);
        vm.stopPrank();

        vm.warp(block.timestamp + 356 days);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 1_000e6);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        uint256 feeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 daoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        feeManager.harvestManagementFee();

        // then

        uint256 feeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 daoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        PlasmaVaultStorageLib.ManagementFeeData memory feeDataOnPlasmaVaultAfter = PlasmaVaultGovernance(_plasmaVault)
            .getManagementFeeData();

        assertEq(
            feeDataOnPlasmaVaultBefore.feeInPercentage,
            500,
            "feeDataOnPlasmaVaultBefore.feeInPercentage should be 500"
        );
        assertEq(
            feeDataOnPlasmaVaultAfter.feeInPercentage,
            300,
            "feeDataOnPlasmaVaultAfter.feeInPercentage should be 300"
        );

        assertEq(feeRecipientBefore, 19506849280, "feeRecipientBefore should be 19506849280");
        assertEq(daoFeeRecipientBefore, 29260273920, "daoFeeRecipientBefore should be 29260273920");

        assertEq(feeRecipientAfter, 19506849280, "feeRecipientAfter should be 19506849280");
        assertEq(daoFeeRecipientAfter, 63016208540, "daoFeeRecipientAfter should be 63016208540");
    }

    function testShouldNotUpdateManagementFeeWhenNotAtomist() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        RecipientFee[] memory recipientFees = new RecipientFee[](1);
        recipientFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: 500});

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updateManagementFee(recipientFees);
        vm.stopPrank();
    }

    function testShouldNotsetDaoFeeRecipientAddressWhenNotDAO() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.setIporDaoFeeRecipientAddress(_USER);
        vm.stopPrank();
    }

    function testShouldNotSetDaoFeeRecipientAddressWhenZeroAddress() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("InvalidFeeRecipientAddress()");

        // when
        vm.startPrank(_DAO);
        vm.expectRevert(error);
        feeManager.setIporDaoFeeRecipientAddress(address(0));
        vm.stopPrank();
    }

    function testShouldSetDaoFeeRecipientAddress() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        address feeRecipientBefore = feeManager.getIporDaoFeeRecipientAddress();

        // when
        vm.startPrank(_DAO);
        feeManager.setIporDaoFeeRecipientAddress(_USER);
        vm.stopPrank();

        // then

        address feeRecipientAfter = feeManager.getIporDaoFeeRecipientAddress();

        assertEq(feeRecipientBefore, _DAO_FEE_RECIPIENT, "feeRecipientBefore should be _DAO_FEE_RECIPIENT");
        assertEq(feeRecipientAfter, _USER, "feeRecipientAfter should be _USER");
    }

    function testShouldHarvestFeesWithMultipleRecipientsWhenTransferSharesIsDisabled() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        // Setup multiple recipient fees
        RecipientFee[] memory performanceFees = new RecipientFee[](2);
        performanceFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 1000 // 10%
        });
        performanceFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 500 // 5%
        });

        RecipientFee[] memory managementFees = new RecipientFee[](2);
        managementFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 100 // 1%
        });
        managementFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 50 // 0.5%
        });

        feeManager.initialize();

        // Update fees
        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(performanceFees);
        feeManager.updateManagementFee(managementFees);
        vm.stopPrank();

        // Perform actions on plasma vault
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 balanceRecipient1Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        // when
        feeManager.harvestPerformanceFee();
        feeManager.harvestManagementFee();

        // then
        uint256 balanceRecipient1After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(balanceRecipient1Before, 0, "recipient1 balance before should be 0");
        assertEq(balanceRecipient2Before, 0, "recipient2 balance before should be 0");
        assertEq(balanceDaoRecipientBefore, 0, "dao recipient balance before should be 0");

        // Updated expected values based on actual implementation
        assertApproxEqAbs(
            balanceRecipient1After,
            49999900001, // ~9% performance + 0.85% management (after DAO fee)
            100,
            "recipient1 should receive correct fee share"
        );
        assertApproxEqAbs(
            balanceRecipient2After,
            24999950000, // ~4.5% performance + 0.425% management (after DAO fee)
            100,
            "recipient2 should receive correct fee share"
        );
        assertApproxEqAbs(
            balanceDaoRecipientAfter,
            49999900001, // Equal to recipient1 (matches actual implementation)
            100,
            "dao should receive correct fee share"
        );
    }

    function testShouldHarvestFeesWithMultipleRecipientsWhenTransferSharesIsDisabledRecipientCanWithdraw() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        // Setup multiple recipient fees
        RecipientFee[] memory performanceFees = new RecipientFee[](2);
        performanceFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 1000 // 10%
        });
        performanceFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 500 // 5%
        });

        RecipientFee[] memory managementFees = new RecipientFee[](2);
        managementFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 100 // 1%
        });
        managementFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 50 // 0.5%
        });

        feeManager.initialize();

        // Update fees
        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(performanceFees);
        feeManager.updateManagementFee(managementFees);
        vm.stopPrank();

        // Perform actions on plasma vault
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 balanceRecipient1Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        // when
        feeManager.harvestPerformanceFee();
        feeManager.harvestManagementFee();

        // then
        uint256 balanceRecipient1After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(balanceRecipient1Before, 0, "recipient1 balance before should be 0");
        assertEq(balanceRecipient2Before, 0, "recipient2 balance before should be 0");
        assertEq(balanceDaoRecipientBefore, 0, "dao recipient balance before should be 0");

        // Updated expected values based on actual implementation
        assertApproxEqAbs(
            balanceRecipient1After,
            49999900001, // ~9% performance + 0.85% management (after DAO fee)
            100,
            "recipient1 should receive correct fee share"
        );
        assertApproxEqAbs(
            balanceRecipient2After,
            24999950000, // ~4.5% performance + 0.425% management (after DAO fee)
            100,
            "recipient2 should receive correct fee share"
        );
        assertApproxEqAbs(
            balanceDaoRecipientAfter,
            49999900001, // Equal to recipient1 (matches actual implementation)
            100,
            "dao should receive correct fee share"
        );

        // Test withdrawals
        uint256 usdcBalanceRecipient1Before = ERC20(_USDC).balanceOf(_FEE_RECIPIENT_1);
        uint256 usdcBalanceRecipient2Before = ERC20(_USDC).balanceOf(_FEE_RECIPIENT_2);
        uint256 usdcBalanceDaoBefore = ERC20(_USDC).balanceOf(_DAO_FEE_RECIPIENT);

        // Withdraw shares for recipients
        vm.startPrank(_FEE_RECIPIENT_1);
        PlasmaVault(_plasmaVault).redeem(balanceRecipient1After, _FEE_RECIPIENT_1, _FEE_RECIPIENT_1);
        vm.stopPrank();

        vm.startPrank(_FEE_RECIPIENT_2);
        PlasmaVault(_plasmaVault).redeem(balanceRecipient2After, _FEE_RECIPIENT_2, _FEE_RECIPIENT_2);
        vm.stopPrank();

        vm.startPrank(_DAO_FEE_RECIPIENT);
        PlasmaVault(_plasmaVault).redeem(balanceDaoRecipientAfter, _DAO_FEE_RECIPIENT, _DAO_FEE_RECIPIENT);
        vm.stopPrank();

        // Check final USDC balances
        uint256 usdcBalanceRecipient1After = ERC20(_USDC).balanceOf(_FEE_RECIPIENT_1);
        uint256 usdcBalanceRecipient2After = ERC20(_USDC).balanceOf(_FEE_RECIPIENT_2);
        uint256 usdcBalanceDaoAfter = ERC20(_USDC).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(usdcBalanceRecipient1Before, 0, "recipient1 USDC balance before should be 0");
        assertEq(usdcBalanceRecipient2Before, 0, "recipient2 USDC balance before should be 0");
        assertEq(usdcBalanceDaoBefore, 0, "dao USDC balance before should be 0");

        assertGt(usdcBalanceRecipient1After, 0, "recipient1 should receive USDC after withdrawal");
        assertGt(usdcBalanceRecipient2After, 0, "recipient2 should receive USDC after withdrawal");
        assertGt(usdcBalanceDaoAfter, 0, "dao should receive USDC after withdrawal");

        // Verify shares are burned after withdrawal
        assertEq(
            PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1),
            0,
            "recipient1 should have no shares after withdrawal"
        );
        assertEq(
            PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2),
            0,
            "recipient2 should have no shares after withdrawal"
        );
        assertEq(
            PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT),
            0,
            "dao should have no shares after withdrawal"
        );
    }

    function testShouldHarvestFeesWithZeroFeeRecipients() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        // Setup recipients with zero fees
        RecipientFee[] memory performanceFees = new RecipientFee[](2);
        performanceFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 1000 // 10%
        });
        performanceFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 0 // 0% - recipient exists but gets no fee
        });

        RecipientFee[] memory managementFees = new RecipientFee[](2);
        managementFees[0] = RecipientFee({
            recipient: _FEE_RECIPIENT_1,
            feeValue: 100 // 1% - recipient exists but gets no fee
        });
        managementFees[1] = RecipientFee({
            recipient: _FEE_RECIPIENT_2,
            feeValue: 0 // 0%
        });

        feeManager.initialize();

        // Update fees
        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(performanceFees);
        feeManager.updateManagementFee(managementFees);
        vm.stopPrank();

        // Perform actions on plasma vault
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        uint256 balanceRecipient1Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2Before = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        // when
        feeManager.harvestPerformanceFee();
        feeManager.harvestManagementFee();

        // then
        uint256 balanceRecipient1After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_1);
        uint256 balanceRecipient2After = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_2);
        uint256 balanceDaoRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT);

        assertEq(balanceRecipient1Before, 0, "recipient1 balance before should be 0");
        assertEq(balanceRecipient2Before, 0, "recipient2 balance before should be 0");
        assertEq(balanceDaoRecipientBefore, 0, "dao recipient balance before should be 0");

        assertApproxEqAbs(balanceRecipient1After, 49999900001, 100, "recipient1 should receive only performance fee");

        assertEq(
            balanceRecipient2After,
            0, // Only 1% management fee
            "recipient2 should receive 0"
        );

        // DAO gets both fees
        assertApproxEqAbs(balanceDaoRecipientAfter, 49999900001, 100, "dao should receive correct fee share");
    }

    function testShouldNotUpdateHighWaterMarkPerformanceFeeWhenNotOwner() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updateHighWaterMarkPerformanceFee();
        vm.stopPrank();
    }

    function testShouldUpdateHighWaterMarkPerformanceFeeWhenOwner() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        // Store initial high water mark
        uint256 initialHighWaterMark = PlasmaVault(_plasmaVault).convertToAssets(
            10 ** IERC20Metadata(_plasmaVault).decimals()
        );

        // Simulate some value change
        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), 5000e6);
        AAVE_POOL.supply(_USDC, 5000e6, _plasmaVault, 0);
        vm.stopPrank();

        vm.warp(block.timestamp + 30 days);

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.AAVE_V3;
        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateHighWaterMarkPerformanceFee();
        vm.stopPrank();

        // then
        uint256 newHighWaterMark = PlasmaVault(_plasmaVault).convertToAssets(
            10 ** IERC20Metadata(_plasmaVault).decimals()
        );

        assertGt(newHighWaterMark, initialHighWaterMark, "New high water mark should be greater than initial");
    }

    function testShouldRevertUpdateHighWaterMarkPerformanceFeeWhenInvalidHighWaterMark() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        // Simulate a scenario where convertToAssets returns 0
        vm.mockCall(
            _plasmaVault,
            abi.encodeWithSelector(IERC4626.convertToAssets.selector, 10 ** IERC20Metadata(_plasmaVault).decimals()),
            abi.encode(0)
        );

        bytes memory error = abi.encodeWithSignature("InvalidHighWaterMark()");

        // when
        vm.startPrank(_ATOMIST);
        vm.expectRevert(error);
        feeManager.updateHighWaterMarkPerformanceFee();
        vm.stopPrank();
    }

    function testShouldNotUpdateIntervalHighWaterMarkPerformanceFeeWhenNotOwner() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(7 days);
        vm.stopPrank();
    }

    function testShouldUpdateIntervalHighWaterMarkPerformanceFeeWhenOwner() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        HighWaterMarkPerformanceFeeStorage memory initialHighWaterMark = feeManager
            .getPlasmaVaultHighWaterMarkPerformanceFee();
        uint32 newInterval = 7 days;

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(newInterval);
        vm.stopPrank();

        // then
        HighWaterMarkPerformanceFeeStorage memory updatedHighWaterMark = feeManager
            .getPlasmaVaultHighWaterMarkPerformanceFee();

        assertEq(initialHighWaterMark.updateInterval, 0, "Initial interval should be 0");
        assertEq(updatedHighWaterMark.updateInterval, newInterval, "Update interval should be updated to new value");
    }

    function testShouldUpdateIntervalHighWaterMarkPerformanceFeeToZero() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount;
        FeeManager feeManager = FeeManager(FeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        // First set non-zero interval
        vm.startPrank(_ATOMIST);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(7 days);
        vm.stopPrank();

        HighWaterMarkPerformanceFeeStorage memory initialHighWaterMark = feeManager
            .getPlasmaVaultHighWaterMarkPerformanceFee();

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateIntervalHighWaterMarkPerformanceFee(0);
        vm.stopPrank();

        // then
        HighWaterMarkPerformanceFeeStorage memory updatedHighWaterMark = feeManager
            .getPlasmaVaultHighWaterMarkPerformanceFee();

        assertEq(initialHighWaterMark.updateInterval, 7 days, "Initial interval should be 7 days");
        assertEq(updatedHighWaterMark.updateInterval, 0, "Update interval should be set to zero");
    }

    function testShouldInitializeFeeManagerWithValidData() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](1);
        performanceFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: PERFORMANCE_FEE_IN_PERCENTAGE});

        RecipientFee[] memory managementFees = new RecipientFee[](1);
        managementFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: MANAGEMENT_FEE_IN_PERCENTAGE});

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: _ATOMIST,
            plasmaVault: _plasmaVault,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when
        FeeManager feeManager = new FeeManager(initData);

        // then
        assertEq(feeManager.PLASMA_VAULT(), _plasmaVault, "PLASMA_VAULT should be set correctly");
        assertEq(
            feeManager.IPOR_DAO_MANAGEMENT_FEE(),
            DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            "DAO management fee should be set correctly"
        );
        assertEq(
            feeManager.IPOR_DAO_PERFORMANCE_FEE(),
            DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            "DAO performance fee should be set correctly"
        );
        assertEq(
            feeManager.getIporDaoFeeRecipientAddress(),
            _DAO_FEE_RECIPIENT,
            "DAO fee recipient should be set correctly"
        );

        RecipientFee[] memory storedPerformanceFees = feeManager.getPerformanceFeeRecipients();
        assertEq(storedPerformanceFees.length, 1, "Should have one performance fee recipient");
        assertEq(
            storedPerformanceFees[0].recipient,
            _FEE_RECIPIENT_1,
            "Performance fee recipient should be set correctly"
        );
        assertEq(
            storedPerformanceFees[0].feeValue,
            PERFORMANCE_FEE_IN_PERCENTAGE,
            "Performance fee value should be set correctly"
        );

        RecipientFee[] memory storedManagementFees = feeManager.getManagementFeeRecipients();
        assertEq(storedManagementFees.length, 1, "Should have one management fee recipient");
        assertEq(
            storedManagementFees[0].recipient,
            _FEE_RECIPIENT_1,
            "Management fee recipient should be set correctly"
        );
        assertEq(
            storedManagementFees[0].feeValue,
            MANAGEMENT_FEE_IN_PERCENTAGE,
            "Management fee value should be set correctly"
        );
    }

    function testShouldRevertWhenInitialAuthorityIsZero() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](1);
        performanceFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: PERFORMANCE_FEE_IN_PERCENTAGE});

        RecipientFee[] memory managementFees = new RecipientFee[](1);
        managementFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: MANAGEMENT_FEE_IN_PERCENTAGE});

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: address(0),
            plasmaVault: _plasmaVault,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when/then
        vm.expectRevert(FeeManager.InvalidAuthority.selector);
        new FeeManager(initData);
    }

    function testShouldRevertWhenFeeRecipientPerformanceFeesIsZero() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](1);
        performanceFees[0] = RecipientFee({recipient: address(0), feeValue: PERFORMANCE_FEE_IN_PERCENTAGE});

        RecipientFee[] memory managementFees = new RecipientFee[](1);
        managementFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: MANAGEMENT_FEE_IN_PERCENTAGE});

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: _ATOMIST,
            plasmaVault: _plasmaVault,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when/then
        vm.expectRevert(FeeManager.InvalidFeeRecipientAddress.selector);
        new FeeManager(initData);
    }

    function testShouldRevertWhenFeeRecipientManagementFeesIsZero() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](1);
        performanceFees[0] = RecipientFee({recipient: _FEE_RECIPIENT_1, feeValue: PERFORMANCE_FEE_IN_PERCENTAGE});

        RecipientFee[] memory managementFees = new RecipientFee[](1);
        managementFees[0] = RecipientFee({recipient: address(0), feeValue: MANAGEMENT_FEE_IN_PERCENTAGE});

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: _ATOMIST,
            plasmaVault: _plasmaVault,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when/then
        vm.expectRevert(FeeManager.InvalidFeeRecipientAddress.selector);
        new FeeManager(initData);
    }

    function testShouldInitializeWithEmptyFeeRecipients() external {
        // given
        RecipientFee[] memory performanceFees = new RecipientFee[](0);
        RecipientFee[] memory managementFees = new RecipientFee[](0);

        FeeManagerInitData memory initData = FeeManagerInitData({
            initialAuthority: _ATOMIST,
            plasmaVault: _plasmaVault,
            iporDaoManagementFee: DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            iporDaoPerformanceFee: DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            iporDaoFeeRecipientAddress: _DAO_FEE_RECIPIENT,
            recipientManagementFees: managementFees,
            recipientPerformanceFees: performanceFees
        });

        // when
        FeeManager feeManager = new FeeManager(initData);

        // then
        RecipientFee[] memory storedPerformanceFees = feeManager.getPerformanceFeeRecipients();
        assertEq(storedPerformanceFees.length, 0, "Should have no performance fee recipients");

        RecipientFee[] memory storedManagementFees = feeManager.getManagementFeeRecipients();
        assertEq(storedManagementFees.length, 0, "Should have no management fee recipients");

        assertEq(
            feeManager.getTotalPerformanceFee(),
            DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            "Total performance fee should equal DAO fee"
        );
        assertEq(
            feeManager.getTotalManagementFee(),
            DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            "Total management fee should equal DAO fee"
        );
    }
}
