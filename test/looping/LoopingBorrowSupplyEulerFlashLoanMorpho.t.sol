// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {WstETHPriceFeedEthereum} from "../../contracts/price_oracle/price_feed/chains/ethereum/WstETHPriceFeedEthereum.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../contracts/vaults/PlasmaVault.sol";
import {EulerFuseLib, EulerSubstrate} from "../../contracts/fuses/euler/EulerFuseLib.sol";
import {EulerV2SupplyFuse, EulerV2SupplyFuseEnterData, EulerV2SupplyFuseExitData} from "../../contracts/fuses/euler/EulerV2SupplyFuse.sol";
import {EulerV2CollateralFuse, EulerV2CollateralFuseEnterData} from "../../contracts/fuses/euler/EulerV2CollateralFuse.sol";
import {EulerV2ControllerFuse, EulerV2ControllerFuseEnterData} from "../../contracts/fuses/euler/EulerV2ControllerFuse.sol";
import {EulerV2BorrowFuse, EulerV2BorrowFuseEnterData, EulerV2BorrowFuseExitData} from "../../contracts/fuses/euler/EulerV2BorrowFuse.sol";
import {EulerV2BalanceFuse} from "../../contracts/fuses/euler/EulerV2BalanceFuse.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {FeeManagerFactory} from "../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../contracts/managers/fee/FeeAccount.sol";
import {IBorrowing} from "../../contracts/fuses/euler/ext/IBorrowing.sol";

import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {IWETH9} from "./IWETH9.sol";
import {IstETH} from "./IstETH.sol";
import {IToken} from "./IToken.sol";

import {ZeroBalanceFuse} from "../../contracts/fuses/ZeroBalanceFuse.sol";
import {MorphoFlashLoanFuse} from "../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MorphoFlashLoanFuseEnterData} from "../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {CallbackHandlerMorpho} from "../../contracts/callback_handlers/CallbackHandlerMorpho.sol";

import {UniswapV3SwapFuse} from "../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";
import {UniswapV3SwapFuseEnterData} from "../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";

struct VaultBalance {
    uint256 eulerPrimeUsdc;
    uint256 eulerWeth;
    uint256 eulerWstEth;
    uint256 eulerUsdt;
    uint256 eulerPrimeWeth;
    uint256 eulerPrimeWstEth;
}

contract LoopingBorrowSupplyEulerFlashLoanMorpho is Test {
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

    /// Morpho Credit Market
    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    /// Uniswap v3
    address private constant _UNIVERSAL_ROUTER = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    uint256 private _errorDelta = 1e3;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;

    address private _eulerSupplyFuse;
    address private _eulerCollateralFuse;
    address private _eulerControllerFuse;
    address private _eulerBorrowFuse;
    address private _morphoFlashLoanFuse;
    address private _uniswapV3SwapFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20990348);

        _priceOracle = _createPriceOracle();

        // plasma vault
        vm.startPrank(_ATOMIST);
        _plasmaVault = address(
            new PlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "USDC",
                    _USDC,
                    _priceOracle,
                    _setupMarketConfigsErc20(),
                    _setupFuses(),
                    _setupBalanceFuses(),
                    _setupFeeConfig(),
                    _createAccessManager(),
                    address(new PlasmaVaultBase()),
                    type(uint256).max,
                    address(0)
                )
            )
        );
        vm.stopPrank();

        _initAccessManager();
        _setupDependenceBalance();
        _initialDepositIntoPlasmaVault();

        _grantMarketSubstratesForEuler();

        _setupCallbackHandler();

        _subAccountOneAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_BYTE_ONE);
        _subAccountTwoAddress = EulerFuseLib.generateSubAccountAddress(_plasmaVault, _SUB_ACCOUNT_BYTE_TWO);
    }

    function _setupCallbackHandler() private {
        CallbackHandlerMorpho callbackHandler = new CallbackHandlerMorpho();
        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            _MORPHO,
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );
        vm.stopPrank();
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
        _morphoFlashLoanFuse = address(new MorphoFlashLoanFuse(IporFusionMarkets.MORPHO_FLASH_LOAN, _MORPHO));
        _uniswapV3SwapFuse = address(new UniswapV3SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V3, _UNIVERSAL_ROUTER));

        fuses = new address[](6);
        fuses[0] = address(_eulerSupplyFuse);
        fuses[1] = address(_eulerCollateralFuse);
        fuses[2] = address(_eulerControllerFuse);
        fuses[3] = address(_eulerBorrowFuse);
        fuses[4] = address(_uniswapV3SwapFuse);
        fuses[5] = address(_morphoFlashLoanFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        EulerV2BalanceFuse eulerBalance = new EulerV2BalanceFuse(IporFusionMarkets.EULER_V2, _EVC);
        ERC20BalanceFuse erc20Balance = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        ZeroBalanceFuse morphoFlashloanBalance = new ZeroBalanceFuse(IporFusionMarkets.MORPHO_FLASH_LOAN);
        ZeroBalanceFuse uniswapBalance = new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3);

        balanceFuses_ = new MarketBalanceFuseConfig[](4);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EULER_V2, address(eulerBalance));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20Balance));
        balanceFuses_[2] = MarketBalanceFuseConfig(
            IporFusionMarkets.MORPHO_FLASH_LOAN,
            address(morphoFlashloanBalance)
        );
        balanceFuses_[3] = MarketBalanceFuseConfig(IporFusionMarkets.UNISWAP_SWAP_V3, address(uniswapBalance));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig(0, 0, 0, 0, address(new FeeManagerFactory()), address(0), address(0));
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
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: address(0),
                feeManager: FeeAccount(PlasmaVaultGovernance(_plasmaVault).getPerformanceFeeData().feeAccount)
                    .FEE_MANAGER()
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](2);
        marketIds[0] = IporFusionMarkets.EULER_V2;
        marketIds[1] = IporFusionMarkets.UNISWAP_SWAP_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](2);
        dependenceMarkets[0] = dependence;
        dependenceMarkets[1] = dependence;

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
        PlasmaVault(_plasmaVault).deposit(1_000e6, _USER);
        vm.stopPrank();

        /// this transfer is only for testing purposes, in production one have to swap underlying assets to this assets
        vm.startPrank(_USER);
        ERC20(_W_ETH).transfer(_plasmaVault, 10e18);
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
        ///  Euler Credit Market
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

        /// Uniswap v3
        bytes32[] memory uniswapTokens = new bytes32[](4);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WST_ETH);
        uniswapTokens[2] = PlasmaVaultConfigLib.addressToBytes32(_USDT);
        uniswapTokens[3] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.UNISWAP_SWAP_V3, uniswapTokens);
        vm.stopPrank();

        /// Morpho Credit Market

        bytes32[] memory morphoTokens = new bytes32[](4);
        morphoTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_W_ETH);
        morphoTokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WST_ETH);
        morphoTokens[2] = PlasmaVaultConfigLib.addressToBytes32(_USDT);
        morphoTokens[3] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.MORPHO_FLASH_LOAN, morphoTokens);
        vm.stopPrank();
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    function testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswap() external {
        /// PlasmaVault init balances:
        /// - 10 WETH on plasma vault
        /// - 1000 USDC on plasma vault
        /// Looping flow:
        /// 1. flash loan 10 WETH from Morpho
        /// 2. supply 20 WETH to Euler
        /// 3. borrow 26360e6 USDC from Euler
        /// 4. swap 26360e6 USDC to WETH on Uniswap
        /// 5. repay 10 WETH to Morpho
        /// State of vault after looping:
        /// - 0.068202379914467642 WETH on plasma vault
        /// - 1000 USDC on plasma vault
        /// - 26360e6 USDC debt on euler
        /// - 20 WETH in Euler vault

        uint256 wethDepositAmount = 20e18;
        uint256 swapAmount = 2636e6 * 10;
        uint256 borrowAmount = 2636e6 * 10;

        /// Setup Euler
        FuseAction[] memory setupEulerMarket = new FuseAction[](2);

        setupEulerMarket[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        setupEulerMarket[1] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(setupEulerMarket);
        vm.stopPrank();

        /// Euler supply/borrow and swap on uniswap

        FuseAction[] memory insideFlashLoan = new FuseAction[](3);

        insideFlashLoan[0] = FuseAction({
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

        insideFlashLoan[1] = FuseAction({
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

        UniswapV3SwapFuseEnterData memory enterData = UniswapV3SwapFuseEnterData({
            tokenInAmount: swapAmount,
            path: abi.encodePacked(_USDC, uint24(500), _W_ETH),
            minOutAmount: 0
        });

        /// morpho flash loan

        insideFlashLoan[2] = FuseAction(
            address(_uniswapV3SwapFuse),
            abi.encodeWithSignature("enter((uint256,uint256,bytes))", enterData)
        );

        MorphoFlashLoanFuseEnterData memory dataFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _W_ETH,
            tokenAmount: 10e18,
            callbackFuseActionsData: abi.encode(insideFlashLoan)
        });

        FuseAction[] memory flashLoanData = new FuseAction[](1);
        flashLoanData[0] = FuseAction(
            address(_morphoFlashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", dataFlashLoan)
        );

        uint256 wethBalanceBefore = ERC20(_W_ETH).balanceOf(_plasmaVault);
        uint256 usdcBalanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);

        uint256 usdcDeptBefore = IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress);

        uint256 wethBalanceBeforeEulerVault = ERC4626(EULER_VAULT_WETH).convertToAssets(
            ERC4626(EULER_VAULT_WETH).balanceOf(_subAccountOneAddress)
        );

        /// execute looping

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(flashLoanData);
        vm.stopPrank();

        /// check state after looping

        uint256 wethBalanceAfter = ERC20(_W_ETH).balanceOf(_plasmaVault);
        uint256 usdcBalanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);

        assertEq(wethBalanceBefore, 10e18, "before: balance of weth on plasma vault should be 10e18");
        assertEq(
            wethBalanceAfter,
            68202379914467642,
            "after: balance of weth on plasma vault should be 68202379914467642"
        );

        assertEq(usdcBalanceBefore, 1_000e6, "before: balance of usdc on plasma vault should be 1_000e6");
        assertEq(usdcBalanceAfter, 1_000e6, "after: balance of usdc on plasma vault should be 1_000e6");

        assertEq(
            ERC4626(EULER_VAULT_PRIME_USDC).balanceOf(_subAccountOneAddress),
            0,
            "balance of usdc on euler vault should be 0"
        );

        assertEq(wethBalanceBeforeEulerVault, 0, "before: balance of weth on euler vault should be 0");
        assertEq(
            ERC4626(EULER_VAULT_WETH).convertToAssets(ERC4626(EULER_VAULT_WETH).balanceOf(_subAccountOneAddress)),
            20e18,
            "balance of weth on euler vault should be 20e18"
        );

        assertEq(usdcDeptBefore, 0, "before: debt of usdc on euler vault should be 0");
        assertEq(
            IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress),
            26360e6,
            "after: debt of usdc on euler vault should be 26360e6"
        );
    }

    function testCreateDebtPositionAndRepay() external {
        // Step 1: Create the debt position (similar to the existing test)
        uint256 wethDepositAmount = 20e18;
        uint256 swapAmount = 2636e6 * 10;
        uint256 borrowAmount = 2636e6 * 10;

        // Setup Euler market
        FuseAction[] memory setupEulerMarket = new FuseAction[](2);
        setupEulerMarket[0] = FuseAction({
            fuse: _eulerCollateralFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2CollateralFuseEnterData({eulerVault: EULER_VAULT_WETH, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });
        setupEulerMarket[1] = FuseAction({
            fuse: _eulerControllerFuse,
            data: abi.encodeWithSignature(
                "enter((address,bytes1))",
                EulerV2ControllerFuseEnterData({eulerVault: EULER_VAULT_PRIME_USDC, subAccount: _SUB_ACCOUNT_BYTE_ONE})
            )
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(setupEulerMarket);
        vm.stopPrank();

        // Create debt position
        FuseAction[] memory createDebtActions = new FuseAction[](3);
        createDebtActions[0] = FuseAction({
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
        createDebtActions[1] = FuseAction({
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
        createDebtActions[2] = FuseAction(
            address(_uniswapV3SwapFuse),
            abi.encodeWithSignature(
                "enter((uint256,uint256,bytes))",
                UniswapV3SwapFuseEnterData({
                    tokenInAmount: swapAmount,
                    path: abi.encodePacked(_USDC, uint24(500), _W_ETH),
                    minOutAmount: 0
                })
            )
        );

        MorphoFlashLoanFuseEnterData memory createDebtFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _W_ETH,
            tokenAmount: 10e18,
            callbackFuseActionsData: abi.encode(createDebtActions)
        });

        FuseAction[] memory createDebtFlashLoanAction = new FuseAction[](1);
        createDebtFlashLoanAction[0] = FuseAction(
            address(_morphoFlashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", createDebtFlashLoan)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(createDebtFlashLoanAction);
        vm.stopPrank();

        // Verify debt position
        assertEq(
            ERC4626(EULER_VAULT_WETH).convertToAssets(ERC4626(EULER_VAULT_WETH).balanceOf(_subAccountOneAddress)),
            20e18,
            "WETH balance in Euler vault should be 20e18"
        );
        assertEq(
            IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress),
            26360e6,
            "USDC debt in Euler vault should be 26360e6"
        );

        // Step 2: Repay the debt
        uint256 repayAmount = 26360e6;
        uint256 withdrawAmount = 20e18;
        uint256 swapAmount2 = 10e18;

        FuseAction[] memory repayDebtActions = new FuseAction[](4);
        repayDebtActions[0] = FuseAction({
            fuse: _eulerBorrowFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2BorrowFuseExitData({
                    eulerVault: EULER_VAULT_PRIME_USDC,
                    maxAmount: repayAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });
        repayDebtActions[1] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2SupplyFuseExitData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: withdrawAmount,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });
        repayDebtActions[2] = FuseAction(
            address(_uniswapV3SwapFuse),
            abi.encodeWithSignature(
                "enter((uint256,uint256,bytes))",
                UniswapV3SwapFuseEnterData({
                    tokenInAmount: swapAmount2,
                    path: abi.encodePacked(_W_ETH, uint24(500), _USDC),
                    minOutAmount: 0
                })
            )
        );
        // Add buffer for potential slippage and fees
        repayDebtActions[3] = FuseAction({
            fuse: _eulerSupplyFuse,
            data: abi.encodeWithSignature(
                "exit((address,uint256,bytes1))",
                EulerV2SupplyFuseEnterData({
                    eulerVault: EULER_VAULT_WETH,
                    maxAmount: 1e18,
                    subAccount: _SUB_ACCOUNT_BYTE_ONE
                })
            )
        });

        MorphoFlashLoanFuseEnterData memory repayDebtFlashLoan = MorphoFlashLoanFuseEnterData({
            token: _USDC,
            tokenAmount: repayAmount + 10e6,
            callbackFuseActionsData: abi.encode(repayDebtActions)
        });

        FuseAction[] memory repayDebtFlashLoanAction = new FuseAction[](1);
        repayDebtFlashLoanAction[0] = FuseAction(
            address(_morphoFlashLoanFuse),
            abi.encodeWithSignature("enter((address,uint256,bytes))", repayDebtFlashLoan)
        );

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(repayDebtFlashLoanAction);
        vm.stopPrank();

        // Verify debt is repaid
        assertApproxEqAbs(
            ERC4626(EULER_VAULT_WETH).convertToAssets(ERC4626(EULER_VAULT_WETH).balanceOf(_subAccountOneAddress)),
            0,
            1e15,
            "WETH balance in Euler vault should be close to 0"
        );
        assertEq(
            IBorrowing(EULER_VAULT_PRIME_USDC).debtOf(_subAccountOneAddress),
            0,
            "USDC debt in Euler vault should be 0"
        );
    }
}
