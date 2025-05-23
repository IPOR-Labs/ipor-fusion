// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {MorphoSupplyFuse, MorphoSupplyFuseEnterData} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoCollateralFuse, MorphoCollateralFuseEnterData} from "../../../contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {MorphoBorrowFuse, MorphoBorrowFuseEnterData, MorphoBorrowFuseExitData} from "../../../contracts/fuses/morpho/MorphoBorrowFuse.sol";
import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";

import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {IWETH9} from "./IWETH9.sol";
import {IstETH} from "./IstETH.sol";
import {IWstETH} from "./IWstETH.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FEE_MANAGER_ID} from "../../../contracts/managers/ManagerIds.sol";

contract MorphoCreditMarketTest is Test {
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;

    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    bytes32 private constant _MORPHO_MARKET_ID = 0xd0e50cdac92fe2172043f5e0c36532c6369d24947e40968f34a5e8819ca9ec5d;

    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    uint256 private _errorDelta = 1e3;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _morphoSupplyFuse;
    address private _morphoCollateralFuse;
    address private _morphoBorrowFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20919795);

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        _priceOracle = _createPriceOracle();
        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));
        // plasma vault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "wstETH",
                    _WST_ETH,
                    _priceOracle,
                    _setupMarketConfigs(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    accessManager,
                    address(new PlasmaVaultBase()),
                    type(uint256).max,
                    withdrawManager
                )
            )
        );
        vm.stopPrank();
        _initAccessManager();
        _setupDependenceBalance();

        deal(_USER, 100_000e18);
        vm.startPrank(_USER);
        IWETH9(_W_ETH).deposit{value: 20_000e18}();
        vm.stopPrank();

        vm.startPrank(_USER);
        IstETH(_ST_ETH).submit{value: 20_001e18}(address(0));
        vm.stopPrank();

        vm.startPrank(_USER);
        ERC20(_ST_ETH).approve(_WST_ETH, 20_000e18);
        IWstETH(_WST_ETH).wrap(20_000e18);
        vm.stopPrank();

        vm.startPrank(_USER);
        ERC20(_WST_ETH).approve(_plasmaVault, 10_000e18);
        PlasmaVault(_plasmaVault).deposit(10_000e18, _USER);

        /// @dev only for test purposes
        ERC20(_W_ETH).transfer(_plasmaVault, 10_000e18);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.MORPHO;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    function _createPriceOracle() private returns (address) {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(_CHAINLINK_REGISTRY);
        PriceOracleMiddleware priceOracle = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        WstETHPriceFeedEthereum wstETHPriceFeed = new WstETHPriceFeedEthereum();

        address[] memory assets = new address[](2);
        address[] memory sources = new address[](2);

        assets[0] = _WST_ETH;
        sources[0] = address(wstETHPriceFeed);

        assets[1] = _W_ETH;
        sources[1] = _ETH_USD_CHAINLINK;

        priceOracle.setAssetsPricesSources(assets, sources);

        return address(priceOracle);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](2);

        bytes32[] memory morphoMarketsId = new bytes32[](2);
        morphoMarketsId[0] = _MORPHO_MARKET_ID;

        bytes32[] memory tokens = new bytes32[](1);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.MORPHO, morphoMarketsId);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _morphoSupplyFuse = address(new MorphoSupplyFuse(IporFusionMarkets.MORPHO, _MORPHO));
        _morphoCollateralFuse = address(new MorphoCollateralFuse(IporFusionMarkets.MORPHO, _MORPHO));
        _morphoBorrowFuse = address(new MorphoBorrowFuse(IporFusionMarkets.MORPHO, _MORPHO));

        fuses = new address[](3);
        fuses[0] = address(_morphoSupplyFuse);
        fuses[1] = address(_morphoCollateralFuse);
        fuses[2] = address(_morphoBorrowFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        MorphoBalanceFuse morphoBalance = new MorphoBalanceFuse(IporFusionMarkets.MORPHO);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.MORPHO, address(morphoBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        accessManager_ = address(new IporFusionAccessManager(_ATOMIST, 0));
        _accessManager = accessManager_;
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        address[] memory dao = new address[](1);
        dao[0] = address(this);

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
                withdrawManager: address(0),
                feeManager: PlasmaVaultGovernance(_plasmaVault).getManager(FEE_MANAGER_ID),
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

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.MORPHO;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    // -------------------------------
    // Test
    // -------------------------------

    function testShouldSupplyWeth() external {
        // given
        uint256 supplyAmount = 5_000e18;

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, supplyAmount);

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488973, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488971, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 0, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 4233703782730813744485, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 8467407565461627488973, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 4233703782730813744486, _errorDelta, "totalInErc20After");
    }

    function testShouldSupplyCollateral() external {
        // given
        uint256 supplyAmount = 5_000e18;

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoCollateralFuseEnterData memory supplyParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488973, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488973, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 0, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 5000000000000000000000, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 8467407565461627488973, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 8467407565461627488973, _errorDelta, "totalInErc20After");
    }

    function testShouldSupplyAndSupplyCollateral() external {
        // given
        uint256 supplyAmount = 5_000e18;

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoCollateralFuseEnterData memory supplyCollateralParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyCollateralParams)
        );

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, supplyAmount);

        enterCalls[1] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488973, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488973, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 0, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 9233703782730813744485, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 8467407565461627488973, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 4233703782730813744486, _errorDelta, "totalInErc20After");
    }

    function testShouldBeAbleToWithdrawFromMorpho() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 withdrawAmount = 1_000e18;

        MorphoCollateralFuseEnterData memory supplyCollateralParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyCollateralParams)
        );

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, supplyAmount);

        enterCalls[1] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("exit((bytes32,uint256))", _MORPHO_MARKET_ID, withdrawAmount)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488971, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488971, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 9233703782730813744485, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 8386963026184650995588, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 4233703782730813744486, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 5080444539276976493383, _errorDelta, "totalInErc20After");
    }

    function testShouldBeAbleToWithdrawCollateralFromMorpho() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 withdrawAmount = 1_000e18;

        MorphoCollateralFuseEnterData memory supplyCollateralParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyCollateralParams)
        );

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, supplyAmount);

        enterCalls[1] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("exit((bytes32,uint256))", _MORPHO_MARKET_ID, withdrawAmount)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488971, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488971, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 9233703782730813744485, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 8233703782730813744485, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 4233703782730813744486, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 4233703782730813744486, _errorDelta, "totalInErc20After");
    }

    function testShouldBeAbleToWithdrawCollateralAndWithdrawFromMorpho() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 withdrawAmount = 1_000e18;

        MorphoCollateralFuseEnterData memory supplyCollateralParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](2);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyCollateralParams)
        );

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(_MORPHO_MARKET_ID, supplyAmount);

        enterCalls[1] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        FuseAction[] memory exitCalls = new FuseAction[](2);
        exitCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("exit((bytes32,uint256))", _MORPHO_MARKET_ID, withdrawAmount)
        );

        exitCalls[1] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("exit((bytes32,uint256))", _MORPHO_MARKET_ID, withdrawAmount)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488971, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488971, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 9233703782730813744485, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 7386963026184650995588, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 4233703782730813744486, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 5080444539276976493383, _errorDelta, "totalInErc20After");
    }

    function testShouldBorrowWhenAmountNotZero() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 borrowAmount = 1_000e18;

        MorphoCollateralFuseEnterData memory supplyParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoBorrowFuseEnterData memory borrowParams = MorphoBorrowFuseEnterData(_MORPHO_MARKET_ID, borrowAmount, 0);

        FuseAction[] memory borrowCalls = new FuseAction[](1);
        borrowCalls[0] = FuseAction(
            address(_morphoBorrowFuse),
            abi.encodeWithSignature("enter((bytes32,uint256,uint256))", borrowParams)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(borrowCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488973, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488973, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 5000000000000000000000, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 4153259243453837251101, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 8467407565461627488973, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 9314148322007790237870, _errorDelta, "totalInErc20After");
    }

    function testShouldBorrowWhenShearsNotZero() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 borrowShears = 5_000e23;

        MorphoCollateralFuseEnterData memory supplyParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoBorrowFuseEnterData memory borrowParams = MorphoBorrowFuseEnterData(_MORPHO_MARKET_ID, 0, borrowShears);

        FuseAction[] memory borrowCalls = new FuseAction[](1);
        borrowCalls[0] = FuseAction(
            address(_morphoBorrowFuse),
            abi.encodeWithSignature("enter((bytes32,uint256,uint256))", borrowParams)
        );

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(borrowCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488973, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488973, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 5000000000000000000000, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 4572743173158242350162, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 8467407565461627488973, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 8894664392303385138810, _errorDelta, "totalInErc20After");
    }

    function testShouldNotBeAbleToSupplyWhenMarketNotApproved() external {
        // given
        uint256 supplyAmount = 5_000e18;
        bytes32 notSupportedMarket = 0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e;

        MorphoSupplyFuseEnterData memory supplyParams = MorphoSupplyFuseEnterData(notSupportedMarket, supplyAmount);

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoSupplyFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        bytes memory error = abi.encodeWithSignature(
            "MorphoSupplyFuseUnsupportedMarket(string,bytes32)",
            "enter",
            notSupportedMarket
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldRepayWhenAmountNotZero() external {
        // given
        uint256 supplyAmount = 5_000e18;
        uint256 borrowAmount = 2_000e18;
        uint256 repayAmount = 1_00e18;

        MorphoCollateralFuseEnterData memory supplyParams = MorphoCollateralFuseEnterData(
            _MORPHO_MARKET_ID,
            supplyAmount
        );

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_morphoCollateralFuse),
            abi.encodeWithSignature("enter((bytes32,uint256))", supplyParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        MorphoBorrowFuseEnterData memory borrowParams = MorphoBorrowFuseEnterData(_MORPHO_MARKET_ID, borrowAmount, 0);

        FuseAction[] memory borrowCalls = new FuseAction[](1);
        borrowCalls[0] = FuseAction(
            address(_morphoBorrowFuse),
            abi.encodeWithSignature("enter((bytes32,uint256,uint256))", borrowParams)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(borrowCalls);
        vm.stopPrank();

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        MorphoBorrowFuseExitData memory repayParams = MorphoBorrowFuseExitData(_MORPHO_MARKET_ID, repayAmount, 0);

        FuseAction[] memory repayCalls = new FuseAction[](1);
        repayCalls[0] = FuseAction(
            address(_morphoBorrowFuse),
            abi.encodeWithSignature("exit((bytes32,uint256,uint256))", repayParams)
        );

        // when

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(repayCalls);
        vm.stopPrank();

        // then
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();
        uint256 totalInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);
        uint256 totalInErc20After = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.ERC20_VAULT_BALANCE
        );

        assertApproxEqAbs(totalAssetsBefore, 18467407565461627488971, _errorDelta, "totalAssetsBefore");
        assertApproxEqAbs(totalAssetsAfter, 18467407565461627488971, _errorDelta, "totalAssetsAfter");

        assertApproxEqAbs(totalInMorphoBefore, 3306518486907674502204, _errorDelta, "totalInMorphoBefore");
        assertApproxEqAbs(totalInMorphoAfter, 3391192562562290777094, _errorDelta, "totalInMorphoAfter");

        assertApproxEqAbs(totalInErc20Before, 10160889078553952986767, _errorDelta, "totalInErc20Before");
        assertApproxEqAbs(totalInErc20After, 10076215002899336711877, _errorDelta, "totalInErc20After");
    }
}
