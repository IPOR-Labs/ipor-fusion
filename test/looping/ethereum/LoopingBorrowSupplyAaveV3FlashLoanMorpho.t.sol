// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";
import {AssetChainlinkPriceFeed} from "../../../contracts/price_oracle/price_feed/AssetChainlinkPriceFeed.sol";

import {MorphoFlashLoanFuseEnterData} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";

import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {MorphoFlashLoanFuse} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MorphoFlashLoanFuseEnterData} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {CallbackHandlerMorpho} from "../../../contracts/handlers/callbacks/CallbackHandlerMorpho.sol";
import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {UniswapV3SwapFuse} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";
import {UniswapV3SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";

import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BorrowFuse, AaveV3BorrowFuseEnterData, AaveV3BorrowFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3BorrowFuse.sol";
import {AaveV3BalanceFuse} from "../../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
<<<<<<< HEAD
import {FEE_MANAGER_ID} from "../../../contracts/managers/ManagerIds.sol";
=======
>>>>>>> develop

struct PlasmaVaultBalancesBefore {
    uint256 totalAssetsBefore;
    uint256 balanceErc20Before;
    uint256 wbtcBalanceBefore;
    uint256 wethBalanceBefore;
}

struct PlasmaVaultBalancesAfter {
    uint256 totalAssetsAfter;
    uint256 balanceErc20After;
    uint256 wbtcBalanceAfter;
    uint256 wethBalanceAfter;
}

contract LoopingBorrowSupplyAaveFlashLoanMorphoTest is Test {
    using MorphoBalancesLib for IMorpho;

    address private constant _WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address private constant _WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    bytes32 private constant _MORPHO_WETH_WBTC_MARKET_ID =
        0x138eec0e4a1937eb92ebc70043ed539661dd7ed5a89fb92a720b341650288a40;
    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    address private constant _PRICE_ORACLE_MIDDLEWARE = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
    address private constant _UNIVERSAL_ROUTER_UNISWAP = 0xEf1c6E67703c7BD7107eed8303Fbe6EC2554BF6B;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address public constant AAVE_PRICE_ORACLE = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;

    // Role Addresses
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

    address private _plasmaVault;
    address private _accessManager;
    address private _withdrawManager;
    address private _morphoFlashLoanFuse;
    address private _uniswapV3SwapFuse;
    address private _aaveSupplyFuse;
    address private _aaveBorrowFuse;

    uint256 private constant _ERROR_TOLERANCE = 100;

    address private _wbtcPriceFeed;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 21069542);
        address wbtcPriceFeed = deployWBTCPriceFeed();
        addWBTCPriceFeedToMiddleware(wbtcPriceFeed);
        deployMinimalPlasmaVaultForWBTC();
        setupInitialRoles();
        _addErc20BalanceFuseAndSubstrate();
        _addMorphoFlashLoanFuseToPlasmaVault();
        _addUniswapV3FuseToPlasmaVault();
        _addAaveFusesToPlasmaVault();
        _setupDependenceBalance();
        _provideWBTCToUser();
    }

    function _addAaveFusesToPlasmaVault() private {
        _aaveSupplyFuse = address(
            new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER)
        );
        _aaveBorrowFuse = address(
            new AaveV3BorrowFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER)
        );

        address[] memory fuses = new address[](2);
        fuses[0] = _aaveSupplyFuse;
        fuses[1] = _aaveBorrowFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        vm.stopPrank();

        address aaveBalanceFuse = address(
            new AaveV3BalanceFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER)
        );

        address[] memory balanceFuses = new address[](1);
        balanceFuses[0] = aaveBalanceFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.AAVE_V3, aaveBalanceFuse);
        vm.stopPrank();

        bytes32[] memory assets = new bytes32[](2);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(_WBTC);
        assets[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.AAVE_V3, assets);
        vm.stopPrank();

        // Add balance dependence for AaveV3 market
        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.AAVE_V3;
        uint256[][] memory dependencies = new uint256[][](1);
        dependencies[0] = new uint256[](1);
        dependencies[0][0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(markets, dependencies);
        vm.stopPrank();
    }

    function deployMinimalPlasmaVaultForWBTC() private returns (address) {
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);

        FeeConfig memory feeConfig = FeeConfigHelper.createZeroFeeConfig();

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
        _withdrawManager = address(new WithdrawManager(address(_accessManager)));

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "WBTC Plasma Vault",
            assetSymbol: "WBTC-PV",
            underlyingToken: _WBTC,
            priceOracleMiddleware: _PRICE_ORACLE_MIDDLEWARE,
            feeConfig: feeConfig,
            accessManager: _accessManager,
            plasmaVaultBase: address(new PlasmaVaultBase()),
            withdrawManager: _withdrawManager
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault(initData));

        vm.stopPrank();

        return _plasmaVault;
    }

    function deployWBTCPriceFeed() private returns (address) {
        address wbtc = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
        address wbtcBtcFeed = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
        address btcUsdFeed = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;

        _wbtcPriceFeed = address(new AssetChainlinkPriceFeed(wbtc, wbtcBtcFeed, btcUsdFeed));

        return address(_wbtcPriceFeed);
    }

    function addWBTCPriceFeedToMiddleware(address priceFeed) private {
        address priceOracleMiddleware = 0xB7018C15279E0f5990613cc00A91b6032066f2f7;
        address priceOracleMiddlewareOwner = 0xF6a9bd8F6DC537675D499Ac1CA14f2c55d8b5569;

        vm.startPrank(priceOracleMiddlewareOwner);
        address[] memory assets = new address[](2);
        assets[0] = _WBTC;
        assets[1] = _WETH;
        address[] memory sources = new address[](2);
        sources[0] = priceFeed;
        sources[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
        PriceOracleMiddleware(priceOracleMiddleware).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function setupInitialRoles() public {
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
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: _withdrawManager,
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

    function _addMorphoFlashLoanFuseToPlasmaVault() private {
        address morphoFlashLoanFuse = address(new MorphoFlashLoanFuse(IporFusionMarkets.MORPHO_FLASH_LOAN, _MORPHO));

        address[] memory fuses = new address[](1);
        fuses[0] = morphoFlashLoanFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        vm.stopPrank();

        // Add ZeroBalanceFuse for MorphoFlashLoan
        address zeroBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.MORPHO_FLASH_LOAN));

        address[] memory zeroBalanceFuses = new address[](1);
        zeroBalanceFuses[0] = zeroBalanceFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.MORPHO_FLASH_LOAN, zeroBalanceFuse);
        vm.stopPrank();

        // Grant market substrates for Morpho Flash Loan (only WBTC and WETH)
        bytes32[] memory morphoTokens = new bytes32[](2);
        morphoTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        morphoTokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WBTC);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.MORPHO_FLASH_LOAN, morphoTokens);
        vm.stopPrank();

        // Set up callback handler for Morpho Flash Loan
        CallbackHandlerMorpho callbackHandler = new CallbackHandlerMorpho();

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateCallbackHandler(
            address(callbackHandler),
            _MORPHO,
            CallbackHandlerMorpho.onMorphoFlashLoan.selector
        );
        vm.stopPrank();

        _morphoFlashLoanFuse = morphoFlashLoanFuse;
    }

    function _addUniswapV3FuseToPlasmaVault() private {
        address uniswapV3SwapFuse = address(
            new UniswapV3SwapFuse(IporFusionMarkets.UNISWAP_SWAP_V3, _UNIVERSAL_ROUTER_UNISWAP)
        );

        address[] memory fuses = new address[](1);
        fuses[0] = uniswapV3SwapFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        vm.stopPrank();

        // Grant market substrates for Uniswap V3 Swap (WBTC, WETH)
        bytes32[] memory uniswapTokens = new bytes32[](2);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WBTC);
        uniswapTokens[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.UNISWAP_SWAP_V3, uniswapTokens);
        vm.stopPrank();

        // Add ZeroBalanceFuse for UniswapV3
        address zeroBalanceFuse = address(new ZeroBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3));
        address[] memory zeroBalanceFuses = new address[](1);
        zeroBalanceFuses[0] = zeroBalanceFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.UNISWAP_SWAP_V3, zeroBalanceFuse);
        vm.stopPrank();

        _uniswapV3SwapFuse = uniswapV3SwapFuse;
    }

    function _setupDependenceBalance() private {
        uint256[] memory marketIds = new uint256[](3);
        marketIds[0] = IporFusionMarkets.MORPHO;
        marketIds[0] = IporFusionMarkets.MORPHO_FLASH_LOAN;
        marketIds[1] = IporFusionMarkets.UNISWAP_SWAP_V3;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](3);
        dependenceMarkets[0] = dependence; // Morpho -> ERC20_VAULT_BALANCE
        dependenceMarkets[1] = dependence; // Uniswap -> ERC20_VAULT_BALANCE
        dependenceMarkets[2] = dependence; // MorphoFlashLoan -> ERC20_VAULT_BALANCE

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
        vm.stopPrank();
    }

    function _addErc20BalanceFuseAndSubstrate() private {
        // Deploy ERC20BalanceFuse
        address erc20BalanceFuse = address(new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE));

        // Add ERC20BalanceFuse to PlasmaVault
        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20BalanceFuse);
        vm.stopPrank();

        // Add WBTC and WETH as substrates for ERC20_VAULT_BALANCE market
        bytes32[] memory substrates = new bytes32[](2);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_WBTC);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();
    }

    function _provideWBTCToUser() private {
        uint256 amountToProvide = 15 * 1e8; // 10 WBTC (WBTC has 8 decimals)

        // Use deal to provide WBTC to _USER
        deal(_WBTC, _USER, amountToProvide);

        // Log the balance
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    function testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswap() external {
        /// Test steps
        /// - User deposit 15 WBTC to plasma vault
        /// - Alpha swap 5 WBTC to WETH
        /// Looping flow:
        /// 1. flash loan 10 WBTC from Morpho
        /// 2. supply 20 WBTC to Morpho market
        /// 3. borrow ???? WETH
        /// 4. swap 2???? WETH to WBTC on Uniswap
        /// 5. repay 10 WBTC to Morpho

        // Deposit 15 WBTC into PlasmaVault
        uint256 depositWbtcAmount = 15 * 1e8; // 15 WBTC (WBTC has 8 decimals)

        vm.startPrank(_USER);
        ERC20(_WBTC).approve(_plasmaVault, depositWbtcAmount);
        PlasmaVault(_plasmaVault).deposit(depositWbtcAmount, _USER);
        vm.stopPrank();

        // Alpha swap 5 WBTC to WETH
        uint256 swapAmount = 5 * 1e8; // 5 WBTC

        UniswapV3SwapFuseEnterData memory swapData = UniswapV3SwapFuseEnterData({
            tokenInAmount: swapAmount,
            path: abi.encodePacked(_WBTC, uint24(3000), _WETH),
            minOutAmount: 0 // Set to 0 for this example, but in production should use a reasonable slippage tolerance
        });

        FuseAction[] memory swapActions = new FuseAction[](1);
        swapActions[0] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(swapActions);
        vm.stopPrank();

        // Prepare action fuses for Morpho and Uniswap operations

        // 1. Provide 20 WETH as collateral to Morpho market
        AaveV3SupplyFuseEnterData memory collateralData = AaveV3SupplyFuseEnterData({
            asset: _WBTC,
            amount: 20 * 1e8, // 20 WBtc
            userEModeCategoryId: 300
        });

        // 2. Borrow 200 WETH from Morpho
        AaveV3BorrowFuseEnterData memory borrowData = AaveV3BorrowFuseEnterData({
            asset: _WETH,
            amount: 300 * 1e18 // 300 WETH
        });

        // 3. Swap 200 WETH to WBTC on Uniswap
        UniswapV3SwapFuseEnterData memory swapBackData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 300 * 1e18, // 300 WETH
            path: abi.encodePacked(_WETH, uint24(3000), _WBTC),
            minOutAmount: 0 // Set to 0 for this example, but in production should use a reasonable slippage tolerance
        });

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction({
            fuse: _aaveSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", collateralData)
        });
        actions[1] = FuseAction({
            fuse: _aaveBorrowFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", borrowData)
        });
        actions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapBackData)
        });

        // Create MorphoFlashLoanFuseEnterData for 10 WBTC flash loan
        MorphoFlashLoanFuseEnterData memory flashLoanData = MorphoFlashLoanFuseEnterData({
            token: _WBTC,
            tokenAmount: 10 * 1e8, // 10 WBTC (WBTC has 8 decimals)
            callbackFuseActionsData: abi.encode(actions)
        });

        // Create FuseAction for Morpho flash loan
        FuseAction[] memory flashLoanAction = new FuseAction[](1);
        flashLoanAction[0] = FuseAction({
            fuse: _morphoFlashLoanFuse,
            data: abi.encodeWithSignature("enter((address,uint256,bytes))", flashLoanData)
        });

        uint256 balanceInAaveV3Before = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);

        uint256 wbtcBalanceBefore = ERC20(_WBTC).balanceOf(_plasmaVault);
        uint256 wethBalanceBefore = ERC20(_WETH).balanceOf(_plasmaVault);

        // Execute the flash loan action
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(flashLoanAction);
        vm.stopPrank();

        // Log final balances after flash loan
        uint256 balanceInAaveV3After = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);

        uint256 wbtcBalanceAfter = ERC20(_WBTC).balanceOf(_plasmaVault);
        uint256 wethBalanceAfter = ERC20(_WETH).balanceOf(_plasmaVault);

        uint256 debtToken = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE).balanceOf(_plasmaVault); // dWETH
        uint256 totalCollateralAssets = PlasmaVault(0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8).balanceOf(_plasmaVault); //aWBTC

        assertApproxEqAbs(balanceInAaveV3Before, 0, _ERROR_TOLERANCE, "balanceInAaveV3Before");
        assertApproxEqAbs(balanceInAaveV3After, 890598528, _ERROR_TOLERANCE, "balanceInAaveV3After");

        assertApproxEqAbs(wbtcBalanceBefore, 10e8, _ERROR_TOLERANCE, "wbtcBalanceBefore");
        assertApproxEqAbs(wbtcBalanceAfter, 101653168, _ERROR_TOLERANCE, "wbtcBalanceAfter");

        assertApproxEqAbs(wethBalanceBefore, 134885142670831652064, _ERROR_TOLERANCE, "wethBalanceBefore");
        assertApproxEqAbs(wethBalanceAfter, 134885142670831652064, _ERROR_TOLERANCE, "wethBalanceAfter");

        assertApproxEqAbs(debtToken, 300e18, _ERROR_TOLERANCE, "debtToken");
        assertApproxEqAbs(totalCollateralAssets, 2000000000, _ERROR_TOLERANCE, "totalCollateralAssets");
    }

    function testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswapAndRepay() external {
        // First part - same as testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswap
        uint256 depositWbtcAmount = 15 * 1e8;

        vm.startPrank(_USER);
        ERC20(_WBTC).approve(_plasmaVault, depositWbtcAmount);
        PlasmaVault(_plasmaVault).deposit(depositWbtcAmount, _USER);
        vm.stopPrank();

        // Alpha swap 5 WBTC to WETH
        uint256 swapAmount = 5 * 1e8;

        UniswapV3SwapFuseEnterData memory swapData = UniswapV3SwapFuseEnterData({
            tokenInAmount: swapAmount,
            path: abi.encodePacked(_WBTC, uint24(3000), _WETH),
            minOutAmount: 0
        });

        FuseAction[] memory swapActions = new FuseAction[](1);
        swapActions[0] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(swapActions);
        vm.stopPrank();

        // 1. Provide 20 WETH as collateral to Morpho market
        AaveV3SupplyFuseEnterData memory collateralData = AaveV3SupplyFuseEnterData({
            asset: _WBTC,
            amount: 20 * 1e8, // 20 WBtc
            userEModeCategoryId: 300
        });

        // 2. Borrow 200 WETH from Morpho
        AaveV3BorrowFuseEnterData memory borrowData = AaveV3BorrowFuseEnterData({
            asset: _WETH,
            amount: 300 * 1e18 // 300 WETH
        });

        // 3. Swap 200 WETH to WBTC on Uniswap
        UniswapV3SwapFuseEnterData memory swapBackData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 300 * 1e18, // 300 WETH
            path: abi.encodePacked(_WETH, uint24(3000), _WBTC),
            minOutAmount: 0 // Set to 0 for this example, but in production should use a reasonable slippage tolerance
        });

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction({
            fuse: _aaveSupplyFuse,
            data: abi.encodeWithSignature("enter((address,uint256,uint256))", collateralData)
        });
        actions[1] = FuseAction({
            fuse: _aaveBorrowFuse,
            data: abi.encodeWithSignature("enter((address,uint256))", borrowData)
        });
        actions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapBackData)
        });

        MorphoFlashLoanFuseEnterData memory flashLoanData = MorphoFlashLoanFuseEnterData({
            token: _WBTC,
            tokenAmount: 10 * 1e8,
            callbackFuseActionsData: abi.encode(actions)
        });

        FuseAction[] memory flashLoanAction = new FuseAction[](1);
        flashLoanAction[0] = FuseAction({
            fuse: _morphoFlashLoanFuse,
            data: abi.encodeWithSignature("enter((address,uint256,bytes))", flashLoanData)
        });

        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(flashLoanAction);
        vm.stopPrank();

        // Second part - repay debt and withdraw using flash loan
        // Create repay actions

        uint256 debtTokenBalanceBefore = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE).balanceOf(_plasmaVault); // dWETH

        AaveV3BorrowFuseExitData memory repayData = AaveV3BorrowFuseExitData({
            asset: _WETH,
            amount: debtTokenBalanceBefore
        });

        uint256 totalCollateralAssetsBefore = PlasmaVault(0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8).balanceOf(
            _plasmaVault
        ); //aWBTC

        AaveV3SupplyFuseExitData memory withdrawData = AaveV3SupplyFuseExitData({
            asset: _WBTC,
            amount: totalCollateralAssetsBefore
        });

        // Swap WBTC back to WETH to repay loan
        UniswapV3SwapFuseEnterData memory swapToRepayData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 20 * 1e8,
            path: abi.encodePacked(_WBTC, uint24(3000), _WETH),
            minOutAmount: 0
        });

        FuseAction[] memory repayActions = new FuseAction[](3);
        repayActions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapToRepayData)
        });
        repayActions[0] = FuseAction({
            fuse: _aaveBorrowFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", repayData)
        });
        repayActions[1] = FuseAction({
            fuse: _aaveSupplyFuse,
            data: abi.encodeWithSignature("exit((address,uint256))", withdrawData)
        });

        MorphoFlashLoanFuseEnterData memory repayFlashLoanData = MorphoFlashLoanFuseEnterData({
            token: _WETH,
            tokenAmount: 300 * 1e18,
            callbackFuseActionsData: abi.encode(repayActions)
        });

        FuseAction[] memory repayFlashLoanAction = new FuseAction[](1);
        repayFlashLoanAction[0] = FuseAction({
            fuse: _morphoFlashLoanFuse,
            data: abi.encodeWithSignature("enter((address,uint256,bytes))", repayFlashLoanData)
        });

        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        // when
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(repayFlashLoanAction);
        vm.stopPrank();

        // then

        uint256 totalCollateralAssetsAfter = PlasmaVault(0x5Ee5bf7ae06D1Be5997A1A72006FE6C607eC6DE8).balanceOf(
            _plasmaVault
        ); //aWBTC

        uint256 debtTokenBalanceAfter = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE).balanceOf(_plasmaVault); // dWETH
        assertApproxEqAbs(debtTokenBalanceAfter, 0, _ERROR_TOLERANCE, "debtTokenBalanceAfter");
        assertApproxEqAbs(totalCollateralAssetsAfter, 0, _ERROR_TOLERANCE, "totalCollateralAssetsAfter");
        assertApproxEqAbs(debtTokenBalanceBefore, 300e18, _ERROR_TOLERANCE, "debtTokenBalanceBefore");

        assertApproxEqAbs(PlasmaVault(_plasmaVault).totalAssets(), 1483705643, _ERROR_TOLERANCE, "totalAssetsAfter");
        assertApproxEqAbs(totalAssetsBefore, 1491057615, _ERROR_TOLERANCE, "totalAssetsBefore");
    }
}
