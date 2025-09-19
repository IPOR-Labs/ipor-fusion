// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IEVC} from "ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {EulerFuseLib, EulerSubstrate} from "../../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData, EulerV2SupplyFuseExitData} from "../../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2CollateralFuse, EulerV2CollateralFuseEnterData, EulerV2CollateralFuseExitData} from "../../../contracts/fuses/euler/EulerV2CollateralFuse.sol";
import {EulerV2ControllerFuse, EulerV2ControllerFuseEnterData, EulerV2ControllerFuseExitData} from "../../../contracts/fuses/euler/EulerV2ControllerFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData, EulerV2BorrowFuseExitData} from "../../../contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerV2BalanceFuse} from "../../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FuseAction, FeeConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {IBorrowing} from "../../../contracts/fuses/euler/ext/IBorrowing.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {IWETH9} from "./IWETH9.sol";
import {IstETH} from "./IstETH.sol";
import {IToken} from "./IToken.sol";

import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";

struct VaultBalance {
    uint256 eulerPrimeUsdc;
    uint256 eulerWeth;
    uint256 eulerWstEth;
    uint256 eulerUsdt;
    uint256 eulerPrimeWeth;
    uint256 eulerPrimeWstEth;
}

contract EulerCreditMarketTest is Test {
    ///  Euler Credit Market
    address private constant _EVC = 0x0C9a3dd6b8F28529d72d7f9cE918D493519EE383;

    ///  Euler Credit Vault
    address private constant EULER_VAULT_PRIME_USDC = 0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9;

    ///  collateral for the EULER_VAULT_PRIME_USDC
    address private constant EULER_VAULT_WETH = 0xb3b36220fA7d12f7055dab5c9FD18E860e9a6bF8;
    address private constant EULER_VAULT_WSTETH = 0xF6E2EfDF175e7a91c8847dade42f2d39A9aE57D4;
    address private constant EULER_VAULT_USDT = 0x2343b4bCB96EC35D8653Fb154461fc673CB20a7e;
    address private constant EULER_VAULT_PRIME_WETH = 0xD8b27CF359b7D15710a5BE299AF6e7Bf904984C2;
    address private constant EULER_VAULT_PRIME_WSTETH = 0xbC4B4AC47582c3E38Ce5940B80Da65401F4628f1;

    ///  assets
    address private constant _W_ETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address private constant _ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private constant _WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    ///  Oracle
    address private constant _ETH_USD_CHAINLINK = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address private constant _CHAINLINK_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;

    ///  Euler sub account
    bytes1 private constant _SUB_ACCOUNT_BYTE_ONE = 0x01;
    bytes1 private constant _SUB_ACCOUNT_BYTE_TWO = 0x02;

    address private _subAccountOneAddress;
    address private _subAccountTwoAddress;

    ///  Plasma Vault tests config
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);

    uint256 private _errorDelta = 1e3;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _eulerSupplyFuse;
    address private _eulerCollateralFuse;
    address private _eulerControllerFuse;
    address private _eulerBorrowFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20990348);

        _priceOracle = _createPriceOracle();

        address accessManager = _createAccessManager();
        address withdrawManager = address(new WithdrawManager(accessManager));

        // plasma vault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).proxyInitialize(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "USDC",
                    _USDC,
                    _priceOracle,
                    _setupFeeConfig(),
                    accessManager,
                    address(new PlasmaVaultBase()),
                    withdrawManager
                )
            );
        vm.stopPrank();

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            _ATOMIST,
            address(_plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigsErc20()
        );

        _initAccessManager();
        _setupDependenceBalance();
        _initialDepositIntoPlasmaVault();
        _grantMarketSubstratesForEuler();

        _subAccountOneAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_BYTE_ONE);
        _subAccountTwoAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_BYTE_TWO);
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

    function _setupMarketConfigsErc20() private returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory tokens = new bytes32[](4);
        tokens[0] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);
        tokens[1] = PlasmaVaultConfigLib.addressToBytes32(_ST_ETH);
        tokens[2] = PlasmaVaultConfigLib.addressToBytes32(_WST_ETH);
        tokens[3] = PlasmaVaultConfigLib.addressToBytes32(_USDT);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, tokens);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _eulerSupplyFuse = address(new EulerV2SupplyFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerCollateralFuse = address(new EulerV2CollateralFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerControllerFuse = address(new EulerV2ControllerFuse(IporFusionMarkets.EULER_V2, _EVC));
        _eulerBorrowFuse = address(new EulerV2BorrowFuse(IporFusionMarkets.EULER_V2, _EVC));

        fuses = new address[](4);
        fuses[0] = address(_eulerSupplyFuse);
        fuses[1] = address(_eulerCollateralFuse);
        fuses[2] = address(_eulerControllerFuse);
        fuses[3] = address(_eulerBorrowFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        EulerV2BalanceFuse eulerBalance = new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);

        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, address(eulerBalance));
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
                rewardsClaimManager: address(0x123),
                withdrawManager: address(0x123),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER(),
                contextManager: address(0x123),
                priceOracleMiddlewareManager: address(0x123)
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
        marketIds[0] = IporFusionMarkets.EULER_V2;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    function _initialDepositIntoPlasmaVault() private {
        deal(_USER, 100_000e18);

        vm.startPrank(_USER);
        IWETH9(_W_ETH).deposit{value: 100e18}();
        IstETH(_ST_ETH).submit{value: 100e18}(address(0));
        vm.stopPrank();

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9); // AmmTreasuryUsdcProxy
        ERC20(_USDC).transfer(_USER, 10_000e6);

        deal(_USDT, _USER, 10_000e6);
        deal(_WST_ETH, _USER, 100e18);

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, 10_000e6);
        PlasmaVault(_plasmaVault).deposit(10_000e6, _USER);
        vm.stopPrank();

        /// this transfer is only for testing purposes, in production one have to swap underlying assets to this assets
        vm.startPrank(_USER);
        ERC20(_W_ETH).transfer(_plasmaVault, 100e18);
        ERC20(_ST_ETH).transfer(_plasmaVault, 100e18);
        ERC20(_WST_ETH).transfer(_plasmaVault, 100e18);
        IToken(_USDT).transfer(_plasmaVault, 10_000e6);
        vm.stopPrank();

        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        PlasmaVault(_plasmaVault).updateMarketsBalances(marketIds);
    }

    function _grantMarketSubstratesForEuler() private {
        bytes32[] memory substrates = new bytes32[](10);
        substrates[0] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: true,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );
        substrates[1] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_WETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );
        substrates[2] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_WSTETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );
        substrates[3] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_USDT,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );
        substrates[4] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_WETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );
        substrates[5] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_WSTETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_ONE
            })
        );

        substrates[6] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_PRIME_USDC,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_TWO
            })
        );
        substrates[7] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_WETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_TWO
            })
        );
        substrates[8] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_WSTETH,
                isCollateral: true,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_TWO
            })
        );
        substrates[9] = EulerFuseLib.substrateToBytes32(
            EulerSubstrate({
                eulerVault: EULER_VAULT_USDT,
                isCollateral: false,
                canBorrow: false,
                subAccounts: _SUB_ACCOUNT_BYTE_TWO
            })
        );

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.EULER_V2, substrates);
        vm.stopPrank();
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    function testShouldDepositToAllCollateralVaultWhenUseAccountOne() public {
        //given
        uint256 wethDepositAmount = 1e18;
        uint256 usdtDepositAmount = 100e6;
        VaultBalance memory eulerVaultsBalanceBefore;
        VaultBalance memory eulerVaultsBalanceAfter;

        FuseAction[] memory enterCalls = new FuseAction[](5);

        enterCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WSTETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_USDT,
                    maxAmount: usdtDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[3] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[4] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WSTETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        eulerVaultsBalanceBefore.eulerPrimeUsdc = ERC4626(EULER_VAULT_PRIME_USDC).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceBefore.eulerWeth = ERC4626(EULER_VAULT_WETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceBefore.eulerWstEth = ERC4626(EULER_VAULT_WSTETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceBefore.eulerUsdt = ERC4626(EULER_VAULT_USDT).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceBefore.eulerPrimeWeth = ERC4626(EULER_VAULT_PRIME_WETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceBefore.eulerPrimeWstEth = ERC4626(EULER_VAULT_PRIME_WSTETH).maxWithdraw(
            _subAccountOneAddress
        );

        uint256 balanceInEulerMarketBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceBefore = PlasmaVault(_plasmaVault).maxWithdraw(_USER);

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        //then

        eulerVaultsBalanceAfter.eulerPrimeUsdc = ERC4626(EULER_VAULT_PRIME_USDC).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceAfter.eulerWeth = ERC4626(EULER_VAULT_WETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceAfter.eulerWstEth = ERC4626(EULER_VAULT_WSTETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceAfter.eulerUsdt = ERC4626(EULER_VAULT_USDT).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceAfter.eulerPrimeWeth = ERC4626(EULER_VAULT_PRIME_WETH).maxWithdraw(_subAccountOneAddress);
        eulerVaultsBalanceAfter.eulerPrimeWstEth = ERC4626(EULER_VAULT_PRIME_WSTETH).maxWithdraw(_subAccountOneAddress);

        uint256 balanceInEulerMarketAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceAfter = PlasmaVault(_plasmaVault).maxWithdraw(_USER);

        assertApproxEqAbs(
            eulerVaultsBalanceBefore.eulerPrimeUsdc,
            eulerVaultsBalanceAfter.eulerPrimeUsdc,
            _errorDelta,
            "eulerPrimeUsdc"
        );

        assertApproxEqAbs(eulerVaultsBalanceBefore.eulerWeth, 0, _errorDelta, "eulerVaultsBalanceBefore.eulerWeth");
        assertApproxEqAbs(
            eulerVaultsBalanceAfter.eulerWeth,
            wethDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceAfter.eulerWeth"
        );

        assertApproxEqAbs(eulerVaultsBalanceBefore.eulerWstEth, 0, _errorDelta, "eulerVaultsBalanceBefore.eulerWstEth");
        assertApproxEqAbs(
            eulerVaultsBalanceAfter.eulerWstEth,
            wethDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceAfter.eulerWstEth"
        );

        assertApproxEqAbs(eulerVaultsBalanceBefore.eulerUsdt, 0, _errorDelta, "eulerVaultsBalanceBefore.eulerUsdt");
        assertApproxEqAbs(
            eulerVaultsBalanceAfter.eulerUsdt,
            usdtDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceAfter.eulerUsdt"
        );

        assertApproxEqAbs(
            eulerVaultsBalanceBefore.eulerPrimeWeth,
            0,
            _errorDelta,
            "eulerVaultsBalanceBefore.eulerPrimeWeth"
        );
        assertApproxEqAbs(
            eulerVaultsBalanceAfter.eulerPrimeWeth,
            wethDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceAfter.eulerPrimeWeth"
        );

        assertApproxEqAbs(
            eulerVaultsBalanceBefore.eulerPrimeWstEth,
            0,
            _errorDelta,
            "eulerVaultsBalanceBefore.eulerPrimeWstEth"
        );
        assertApproxEqAbs(
            eulerVaultsBalanceAfter.eulerPrimeWstEth,
            wethDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceAfter.eulerPrimeWstEth"
        );

        assertApproxEqAbs(balanceInEulerMarketBefore, 0, _errorDelta, "balanceInEulerMarketBefore");
        assertApproxEqAbs(balanceInEulerMarketAfter, 11518270494, _errorDelta, "balanceInEulerMarketAfter");

        assertApproxEqAbs(plasmaVaultBalanceBefore, plasmaVaultBalanceAfter, _errorDelta, "plasmaVaultBalance");
    }

    function testShouldWithdrawFromEulerVaultWhenUseAccountOne() public {
        //given
        uint256 wethDepositAmount = 1e18;
        VaultBalance memory eulerVaultsBalanceBefore;
        VaultBalance memory eulerVaultsBalanceAfter;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        eulerVaultsBalanceBefore.eulerWeth = ERC4626(EULER_VAULT_WETH).maxWithdraw(_subAccountOneAddress);

        uint256 balanceInEulerMarketBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceBefore = PlasmaVault(_plasmaVault).maxWithdraw(_USER);

        FuseAction[] memory exitCalls = new FuseAction[](1);

        exitCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2SupplyFuseExitData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        //when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        //then

        eulerVaultsBalanceAfter.eulerWeth = ERC4626(EULER_VAULT_WETH).maxWithdraw(_subAccountOneAddress);

        uint256 balanceInEulerMarketAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceAfter = PlasmaVault(_plasmaVault).maxWithdraw(_USER);

        assertApproxEqAbs(
            eulerVaultsBalanceBefore.eulerWeth,
            wethDepositAmount,
            _errorDelta,
            "eulerVaultsBalanceBefore.eulerWeth"
        );
        assertApproxEqAbs(eulerVaultsBalanceAfter.eulerWeth, 0, _errorDelta, "eulerVaultsBalanceAfter.eulerWeth");

        assertApproxEqAbs(balanceInEulerMarketBefore, 2614717710, _errorDelta, "balanceInEulerMarketBefore");
        assertApproxEqAbs(balanceInEulerMarketAfter, 0, _errorDelta, "balanceInEulerMarketAfter");

        assertApproxEqAbs(plasmaVaultBalanceBefore, plasmaVaultBalanceAfter, _errorDelta, "plasmaVaultBalance");
    }

    function testShouldNotDepositWhenSubAccountNotApproved() external {
        //given
        uint256 wethDepositAmount = 1e18;

        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WSTETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_TWO
                })
            )
        });

        bytes memory error = abi.encodeWithSignature(
            "EulerV2SupplyFuseUnsupportedEnterAction(address,bytes1)",
            EULER_VAULT_PRIME_WSTETH,
            _SUB_ACCOUNT_BYTE_TWO
        );

        //when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldEnableVaultAsCollateralForSubAccountOne() external {
        FuseAction[] memory enterCalls = new FuseAction[](5);

        enterCalls[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WSTETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_USDT, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[3] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_PRIME_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[4] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WSTETH,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        address[] memory collateralsBefore = IEVC(_EVC).getCollaterals(_subAccountOneAddress);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        address[] memory collateralsAfter = IEVC(_EVC).getCollaterals(_subAccountOneAddress);

        assertEq(collateralsBefore.length, 0, "collateralsBefore.length");
        assertEq(collateralsAfter.length, 5, "collateralsAfter.length");
    }

    function testShouldNotEnableVaultAsCollateralForSubAccountTwoWhenNotApprovedByAtomist() external {
        FuseAction[] memory enterCalls = new FuseAction[](5);

        enterCalls[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_TWO})
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WSTETH, subAccount: _SUB_ACCOUNT_BYTE_TWO})
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_USDT, subAccount: _SUB_ACCOUNT_BYTE_TWO})
            )
        });

        enterCalls[3] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_PRIME_WETH, subAccount: _SUB_ACCOUNT_BYTE_TWO})
            )
        });

        enterCalls[4] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WSTETH,
                    subAccount: _SUB_ACCOUNT_BYTE_TWO
                })
            )
        });

        bytes memory error = abi.encodeWithSignature(
            "EulerV2CollateralFuseUnsupportedEnterAction(address,bytes1)",
            EULER_VAULT_USDT,
            _SUB_ACCOUNT_BYTE_TWO
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldDisableCollateral() external {
        FuseAction[] memory enterCalls = new FuseAction[](5);

        enterCalls[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WSTETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_USDT, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[3] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_PRIME_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[4] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_WSTETH,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        address[] memory collateralsBefore = IEVC(_EVC).getCollaterals(_subAccountOneAddress);

        FuseAction[] memory exitCalls = new FuseAction[](3);

        exitCalls[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "exit((address,bytes1))",
                EulerV2CollateralFuseExitData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        exitCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "exit((address,bytes1))",
                EulerV2CollateralFuseExitData({eulerVault: EULER_VAULT_WSTETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        exitCalls[2] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "exit((address,bytes1))",
                EulerV2CollateralFuseExitData({eulerVault: EULER_VAULT_USDT, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        address[] memory collateralsAfter = IEVC(_EVC).getCollaterals(_subAccountOneAddress);

        assertEq(collateralsBefore.length, 5, "collateralsBefore.length");
        assertEq(collateralsAfter.length, 2, "collateralsAfter.length");
    }

    function testShouldEnableVaultAsControllerForSubAccountOne() external {
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        address[] memory controllersBefore = IEVC(_EVC).getControllers(_subAccountOneAddress);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        // then
        address[] memory controllersAfter = IEVC(_EVC).getControllers(_subAccountOneAddress);

        assertEq(controllersBefore.length, 0, "controllerBefore");
        assertEq(controllersAfter[0], EULER_VAULT_PRIME_USDC, "controllerAfter");
    }

    function testShouldNotEnableVaultAsControllerForSubAccountTwoWhenAtomistNorAccept() external {
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_TWO})
            )
        });

        bytes memory error = abi.encodeWithSignature(
            "EulerV2ControllerFuseUnsupportedEnterAction(address,bytes1)",
            EULER_VAULT_PRIME_USDC,
            _SUB_ACCOUNT_BYTE_TWO
        );

        // when
        vm.startPrank(_ALPHA);
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();
    }

    function testShouldDisableController() external {
        FuseAction[] memory enterCalls = new FuseAction[](1);

        enterCalls[0] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        address[] memory controllersBefore = IEVC(_EVC).getControllers(_subAccountOneAddress);

        FuseAction[] memory exitCalls = new FuseAction[](1);

        exitCalls[0] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "exit((address,bytes1))",
                EulerV2ControllerFuseExitData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(exitCalls);
        vm.stopPrank();

        // then
        address[] memory controllersAfter = IEVC(_EVC).getControllers(_subAccountOneAddress);

        assertEq(controllersBefore.length, 1, "controllerBefore");
        assertEq(controllersAfter.length, 0, "controllerAfter");
    }

    function testShouldBeAbleToBorrow() external {
        //given
        uint256 wethDepositAmount = 100e18;
        uint256 borrowAmount = 1_000e6;
        FuseAction[] memory enterCalls = new FuseAction[](3);

        enterCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        FuseAction[] memory borrowCalls = new FuseAction[](1);

        borrowCalls[0] = FuseAction({
            fuse: _eulerBorrowFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2BorrowFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    assetAmount: borrowAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        uint256 balanceInEulerMarketBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceBefore = PlasmaVault(_plasmaVault).maxWithdraw(_USER);
        uint256 plasmaVaultUsdcBalanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(borrowCalls);
        vm.stopPrank();

        // then

        uint256 balanceInEulerMarketAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceAfter = PlasmaVault(_plasmaVault).maxWithdraw(_USER);
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);

        assertApproxEqAbs(balanceInEulerMarketBefore, 261471771078, _errorDelta, "balanceInEulerMarketBefore");
        assertApproxEqAbs(balanceInEulerMarketAfter, 260471771078, _errorDelta, "balanceInEulerMarketAfter");

        assertApproxEqAbs(plasmaVaultBalanceBefore, plasmaVaultBalanceAfter, _errorDelta, "plasmaVaultBalance");

        assertApproxEqAbs(plasmaVaultUsdcBalanceBefore, 10_000e6, _errorDelta, "plasmaVaultUsdcBalanceBefore");
        assertApproxEqAbs(plasmaVaultUsdcBalanceAfter, 11_000e6, _errorDelta, "plasmaVaultUsdcBalanceAfter");
    }

    function testShouldBeAbleToRepay() external {
        //given
        uint256 wethDepositAmount = 100e18;
        uint256 borrowAmount = 1_000e6;

        FuseAction[] memory enterCalls = new FuseAction[](4);

        enterCalls[0] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: wethDepositAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        enterCalls[1] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[2] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        enterCalls[3] = FuseAction({
            fuse: _eulerBorrowFuse,
            data: abi.encodeWithSignature(
                "enter((address,uint256,bytes1))",
                EulerV2BorrowFuseEnterData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    assetAmount: borrowAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(enterCalls);
        vm.stopPrank();

        FuseAction[] memory repayCalls = new FuseAction[](1);

        repayCalls[0] = FuseAction({
            fuse: _eulerBorrowFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2BorrowFuseExitData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    maxAssetAmount: borrowAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        uint256 balanceInEulerMarketBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceBefore = PlasmaVault(_plasmaVault).maxWithdraw(_USER);
        uint256 plasmaVaultUsdcBalanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        uint256 deptBalanceBefore = IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress);

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(repayCalls);
        vm.stopPrank();

        // then

        uint256 balanceInEulerMarketAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.EULER_V2);
        uint256 plasmaVaultBalanceAfter = PlasmaVault(_plasmaVault).maxWithdraw(_USER);
        uint256 plasmaVaultUsdcBalanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);
        uint256 deptBalanceAfter = IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress);

        assertApproxEqAbs(deptBalanceBefore, 1_000e6, _errorDelta, "deptBalanceBefore");
        assertApproxEqAbs(deptBalanceAfter, 0, _errorDelta, "deptBalanceAfter");

        assertApproxEqAbs(balanceInEulerMarketBefore, 260471771078, _errorDelta, "balanceInEulerMarketBefore");
        assertApproxEqAbs(balanceInEulerMarketAfter, 261471771078, _errorDelta, "balanceInEulerMarketAfter");
        //
        assertApproxEqAbs(plasmaVaultBalanceBefore, plasmaVaultBalanceAfter, _errorDelta, "plasmaVaultBalance");
        //
        assertApproxEqAbs(plasmaVaultUsdcBalanceBefore, 11_000e6, _errorDelta, "plasmaVaultUsdcBalanceBefore");
        assertApproxEqAbs(plasmaVaultUsdcBalanceAfter, 10_000e6, _errorDelta, "plasmaVaultUsdcBalanceAfter");
    }
}
