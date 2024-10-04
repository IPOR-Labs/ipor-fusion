// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {MarketSubstratesConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {IporFeeFactory} from "../../contracts/managers/fee/IporFeeFactory.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionFeeManager} from "../../contracts/managers/fee/IporFusionFeeManager.sol";
import {IporFeeAccount} from "../../contracts/managers/fee/IporFeeAccount.sol";

import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";

import {IPool} from "../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IAavePriceOracle} from "../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";

contract FeeManagerTest is Test {
    address private constant _DAO = address(9999999);
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _FEE_RECIPIENT_ADDRESS = address(5555);
    address private constant _DAO_FEE_RECIPIENT_ADDRESS = address(6666);

    address private constant _USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant _USDC_HOLDER = 0x47c031236e19d024b42f8AE6780E44A573170703;

    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654);
    address public constant ARBITRUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654;

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
                    marketSubstratesConfigs: _setupMarketConfigs(),
                    fuses: _createFuse(),
                    balanceFuses: _setupBalanceFuses(),
                    feeConfig: _setupFeeConfig(),
                    accessManager: address(_accessManager),
                    plasmaVaultBase: address(new PlasmaVaultBase()),
                    totalSupplyCap: type(uint256).max,
                    withdrawManager: address(0)
                })
            )
        );
        vm.stopPrank();
    }

    function _createFuse() private returns (address[] memory) {
        address[] memory fuses = new address[](1);
        fuses[0] = address(
            new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, address(AAVE_POOL), address(AAVE_POOL_DATA_PROVIDER))
        );
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
            fuse: address(
                new AaveV3BalanceFuse(
                    IporFusionMarkets.AAVE_V3,
                    address(AAVE_PRICE_ORACLE),
                    address(AAVE_POOL_DATA_PROVIDER)
                )
            )
        });
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig(
            DAO_MANAGEMENT_FEE_IN_PERCENTAGE,
            DAO_PERFORMANCE_FEE_IN_PERCENTAGE,
            MANAGEMENT_FEE_IN_PERCENTAGE,
            PERFORMANCE_FEE_IN_PERCENTAGE,
            address(new IporFeeFactory()),
            _FEE_RECIPIENT_ADDRESS,
            _DAO_FEE_RECIPIENT_ADDRESS
        );
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
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
            iporDaos: dao,
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: whitelist,
            guardians: initAddress,
            fuseManagers: initAddress,
            performanceFeeManagers: new address[](0),
            managementFeeManagers: new address[](0),
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: address(0),
                feeManager: IporFeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager)
                    .FEE_MANAGER()
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function testShouldHaveShearsOnManagementFeeAccount() external {
        //given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeManager;

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
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(managementAccount).FEE_MANAGER());

        vm.warp(block.timestamp + 356 days);
        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 1_000e6);
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        feeManager.initialize();

        uint256 balanceManagementAccountBefore = PlasmaVault(_plasmaVault).balanceOf(managementAccount);
        uint256 balanceFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_ADDRESS);
        uint256 balanceDaoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT_ADDRESS);

        //when
        feeManager.harvestManagementFee();

        //then
        uint256 balanceManagementAccountAfter = PlasmaVault(_plasmaVault).balanceOf(managementAccount);
        uint256 balanceFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_ADDRESS);
        uint256 balanceDaoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT_ADDRESS);

        assertEq(balanceManagementAccountBefore, 48767123200, "balanceManagementAccountBefore should be 48767123200");
        assertEq(balanceManagementAccountAfter, 0, "balanceManagementAccountAfter should be 0");

        assertEq(balanceFeeRecipientBefore, 0, "balanceFeeRecipientBefore should be 0");
        assertEq(balanceFeeRecipientAfter, 19506849280, "balanceFeeRecipientAfter should be 19506849280");

        assertEq(balanceDaoFeeRecipientBefore, 0, "balanceDaoFeeRecipientBefore should be 0");
        assertEq(balanceDaoFeeRecipientAfter, 29260273920, "balanceDaoFeeRecipientAfter should be 29260273920");
    }

    function testShouldHaveShearsOnPerformanceFeeAccount() external {
        //given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;

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
        assertEq(balanceAfter, 68199104783, "balanceAfter should be 68199104783");
    }

    function testShouldHarvestPerformance() external {
        //given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

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
        uint256 balanceFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_ADDRESS);
        uint256 balanceDaoFeeRecipientBefore = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT_ADDRESS);

        //when
        feeManager.harvestPerformanceFee();

        //then
        uint256 balancePerformanceAccountAfter = PlasmaVault(_plasmaVault).balanceOf(performanceAccount);
        uint256 balanceFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_FEE_RECIPIENT_ADDRESS);
        uint256 balanceDaoFeeRecipientAfter = PlasmaVault(_plasmaVault).balanceOf(_DAO_FEE_RECIPIENT_ADDRESS);

        assertEq(balancePerformanceAccountBefore, 68199104783, "balancePerformanceAccountBefore should be 68199104783");
        assertEq(balancePerformanceAccountAfter, 0, "balancePerformanceAccountAfter should be 0");

        assertEq(balanceFeeRecipientBefore, 0, "balanceFeeRecipientBefore should be 0");
        assertEq(balanceFeeRecipientAfter, 34099552392, "balanceFeeRecipientAfter should be 34099552392");

        assertEq(balanceDaoFeeRecipientBefore, 0, "balanceDaoFeeRecipientBefore should be 0");
        assertEq(balanceDaoFeeRecipientAfter, 34099552391, "balanceDaoFeeRecipientAfter should be 34099552392");
    }

    function testShouldNotHarvestManagementFeeWhenNotInitialize() external {
        // given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(managementAccount).FEE_MANAGER());

        bytes memory error = abi.encodeWithSignature("NotInitialized()");

        // when
        vm.expectRevert(error);
        feeManager.harvestManagementFee();
    }

    function testShouldNotHarvestPerformanceFeeWhenNotInitialize() external {
        // given
        address managementAccount = PlasmaVaultGovernance(_plasmaVault).getManagementFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(managementAccount).FEE_MANAGER());

        bytes memory error = abi.encodeWithSignature("NotInitialized()");

        // when
        vm.expectRevert(error);
        feeManager.harvestPerformanceFee();
    }

    function testShouldNotUpdatePerformanceFeeWhenNotAtomist() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updatePerformanceFee(500);
        vm.stopPrank();
    }

    function testShouldUpdatePerformanceFeeWhenAtomist() external {
        // given
        PlasmaVaultStorageLib.PerformanceFeeData memory feeDataOnPlasmaVaultBefore = PlasmaVaultGovernance(_plasmaVault)
            .getPerformanceFeeData();
        IporFusionFeeManager feeManager = IporFusionFeeManager(
            IporFeeAccount(feeDataOnPlasmaVaultBefore.feeManager).FEE_MANAGER()
        );

        uint256 performanceFeeBefore = feeManager.plasmaVaultPerformanceFee();

        feeManager.initialize();

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updatePerformanceFee(500);
        vm.stopPrank();

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeDataOnPlasmaVaultAfter = PlasmaVaultGovernance(_plasmaVault)
            .getPerformanceFeeData();

        uint256 performanceFeeAfter = feeManager.plasmaVaultPerformanceFee();

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
        IporFusionFeeManager feeManager = IporFusionFeeManager(
            IporFeeAccount(feeDataOnPlasmaVaultBefore.feeManager).FEE_MANAGER()
        );

        uint256 managementFeeBefore = feeManager.plasmaVaultManagementFee();

        feeManager.initialize();

        // when
        vm.startPrank(_ATOMIST);
        feeManager.updateManagementFee(50);
        vm.stopPrank();

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeDataOnPlasmaVaultAfter = PlasmaVaultGovernance(_plasmaVault)
            .getManagementFeeData();

        uint256 managementFeeAfter = feeManager.plasmaVaultManagementFee();

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

    function testShouldNotUpdateManagementFeeWhenNotAtomist() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.updateManagementFee(500);
        vm.stopPrank();
    }

    function testShouldNotSetFeeRecipientAddressWhenNotAtomist() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", _USER);

        // when
        vm.startPrank(_USER);
        vm.expectRevert(error);
        feeManager.setFeeRecipientAddress(_USER);
        vm.stopPrank();
    }

    function testShouldNotSetFeeRecipientAddressWhenZeroAddress() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("WrongAddress()");

        // when
        vm.startPrank(_ATOMIST);
        vm.expectRevert(error);
        feeManager.setFeeRecipientAddress(address(0));
        vm.stopPrank();
    }

    function testShouldSetFeeRecipientAddress() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        address feeRecipientBefore = feeManager.feeRecipientAddress();

        // when
        vm.startPrank(_ATOMIST);
        feeManager.setFeeRecipientAddress(_USER);
        vm.stopPrank();

        // then

        address feeRecipientAfter = feeManager.feeRecipientAddress();

        assertEq(feeRecipientBefore, _FEE_RECIPIENT_ADDRESS, "feeRecipientBefore should be _FEE_RECIPIENT_ADDRESS");
        assertEq(feeRecipientAfter, _USER, "feeRecipientAfter should be _USER");
    }

    function testShouldNotsetDaoFeeRecipientAddressWhenNotDAO() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

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
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        bytes memory error = abi.encodeWithSignature("WrongAddress()");

        // when
        vm.startPrank(_DAO);
        vm.expectRevert(error);
        feeManager.setIporDaoFeeRecipientAddress(address(0));
        vm.stopPrank();
    }

    function testShouldSetDaoFeeRecipientAddress() external {
        // given
        address performanceAccount = PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeManager;
        IporFusionFeeManager feeManager = IporFusionFeeManager(IporFeeAccount(performanceAccount).FEE_MANAGER());

        feeManager.initialize();

        address feeRecipientBefore = feeManager.iporDaoFeeRecipientAddress();

        // when
        vm.startPrank(_DAO);
        feeManager.setIporDaoFeeRecipientAddress(_USER);
        vm.stopPrank();

        // then

        address feeRecipientAfter = feeManager.iporDaoFeeRecipientAddress();

        assertEq(
            feeRecipientBefore,
            _DAO_FEE_RECIPIENT_ADDRESS,
            "feeRecipientBefore should be _DAO_FEE_RECIPIENT_ADDRESS"
        );
        assertEq(feeRecipientAfter, _USER, "feeRecipientAfter should be _USER");
    }

    function testTT() public {
        assertTrue(true);
    }
}
