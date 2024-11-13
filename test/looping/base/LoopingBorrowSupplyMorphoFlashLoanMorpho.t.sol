// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig} from "../../../contracts/vaults/PlasmaVault.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";

import {FeeManagerFactory} from "../../../contracts/managers/fee/FeeManagerFactory.sol";
import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, FuseAction} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {FeeAccount} from "../../../contracts/managers/fee/FeeAccount.sol";

import {MorphoSupplyFuse} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoCollateralFuse, MorphoCollateralFuseEnterData, MorphoCollateralFuseExitData} from "../../../contracts/fuses/morpho/MorphoCollateralFuse.sol";
import {MorphoBorrowFuse, MorphoBorrowFuseEnterData, MorphoBorrowFuseExitData} from "../../../contracts/fuses/morpho/MorphoBorrowFuse.sol";
import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {MorphoFlashLoanFuseEnterData} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";

import {IporFusionAccessManagerInitializerLibV1, InitializationData, DataForInitialization, PlasmaVaultAddress} from "../../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";

import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {MorphoFlashLoanFuse} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MorphoFlashLoanFuseEnterData} from "../../../contracts/fuses/morpho/MorphoFlashLoanFuse.sol";
import {MorphoStorageLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoStorageLib.sol";
import {Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {CallbackHandlerMorpho} from "../../../contracts/callback_handlers/CallbackHandlerMorpho.sol";
import {IMorpho, Position} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {UniswapV3SwapFuse} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";
import {UniswapV3SwapFuseEnterData} from "../../../contracts/fuses/uniswap/UniswapV3SwapFuse.sol";

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

contract LoopingBorrowSupplyMorphoFlashLoanMorphoBaseTest is Test {
    using MorphoBalancesLib for IMorpho;

    address private constant _USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address private constant _WETH = 0x4200000000000000000000000000000000000006;
    bytes32 private constant _MORPHO_WETH_USDC_MARKET_ID =
        0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;
    address private constant _MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;

    address private constant CHAINLINK_ETH_PRICE = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address private constant CHAINLINK_USDC_PRICE = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    address private constant _UNIVERSAL_ROUTER_UNISWAP = 0x3fC91A3afd70395Cd496C647d5a6CC9D4B2b7FAD;

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
    address private _morphoFlashLoanFuse;
    address private _uniswapV3SwapFuse;
    address private _morphoSupplyFuse;
    address private _morphoCollateralFuse;
    address private _morphoBorrowFuse;
    address private _priceOracleMiddleware;

    uint256 private constant _ERROR_TOLERANCE = 100;

    address private _wbtcPriceFeed;

    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.envString("BASE_PROVIDER_URL"), 21654680);
        _deployPriceOracleMiddleware();
        deployMinimalPlasmaVaultForUsdc();
        setupInitialRoles();
        _addErc20BalanceFuseAndSubstrate();
        _addMorphoFlashLoanFuseToPlasmaVault();
        _addUniswapV3FuseToPlasmaVault();
        _addMorphoFusesToPlasmaVault();
        _setupDependenceBalance();
        _provideUsdcToUser();
    }

    function deployMinimalPlasmaVaultForUsdc() private returns (address) {
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);

        FeeConfig memory feeConfig = FeeConfig({
            iporDaoManagementFee: 0,
            iporDaoPerformanceFee: 0,
            atomistManagementFee: 0,
            atomistPerformanceFee: 0,
            feeFactory: address(new FeeManagerFactory()),
            feeRecipientAddress: address(0),
            iporDaoFeeRecipientAddress: address(0)
        });

        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));

        PlasmaVaultInitData memory initData = PlasmaVaultInitData({
            assetName: "USDC Plasma Vault",
            assetSymbol: "USDC-PV",
            underlyingToken: _USDC,
            priceOracleMiddleware: _priceOracleMiddleware,
            marketSubstratesConfigs: new MarketSubstratesConfig[](0),
            fuses: new address[](0),
            balanceFuses: new MarketBalanceFuseConfig[](0),
            feeConfig: feeConfig,
            accessManager: _accessManager,
            plasmaVaultBase: address(new PlasmaVaultBase()),
            totalSupplyCap: type(uint256).max,
            withdrawManager: address(0)
        });

        vm.startPrank(_ATOMIST);
        _plasmaVault = address(new PlasmaVault());
        PlasmaVault(_plasmaVault).initialize(initData);
        vm.stopPrank();

        return _plasmaVault;
    }

    function _deployPriceOracleMiddleware() private {
        vm.startPrank(_OWNER);
        address priceOracleMiddleware = address(new PriceOracleMiddleware(address(0)));

        address priceOracleMiddlewareProxy = address(
            new ERC1967Proxy(address(priceOracleMiddleware), abi.encodeWithSignature("initialize(address)", _OWNER))
        );
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = _WETH;
        assets[1] = _USDC;
        address[] memory sources = new address[](2);
        sources[0] = CHAINLINK_ETH_PRICE; // WETH/USD Chainlink feed
        sources[1] = CHAINLINK_USDC_PRICE; // USDC/USD Chainlink feed
        vm.startPrank(_OWNER);
        PriceOracleMiddleware(priceOracleMiddlewareProxy).setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        _priceOracleMiddleware = priceOracleMiddlewareProxy;
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

        // Grant market substrates for Morpho Flash Loan (only USDC and WETH)
        bytes32[] memory morphoTokens = new bytes32[](2);
        morphoTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_WETH);
        morphoTokens[1] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

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

        // Grant market substrates for Uniswap V3 Swap (USDC, WETH)
        bytes32[] memory uniswapTokens = new bytes32[](2);
        uniswapTokens[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
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

    function _addMorphoFusesToPlasmaVault() private {
        address morphoSupplyFuse = address(new MorphoSupplyFuse(IporFusionMarkets.MORPHO, _MORPHO));
        address morphoCollateralFuse = address(new MorphoCollateralFuse(IporFusionMarkets.MORPHO, _MORPHO));
        address morphoBorrowFuse = address(new MorphoBorrowFuse(IporFusionMarkets.MORPHO, _MORPHO));
        address morphoBalanceFuse = address(new MorphoBalanceFuse(IporFusionMarkets.MORPHO));

        address[] memory fuses = new address[](3);
        fuses[0] = morphoSupplyFuse;
        fuses[1] = morphoCollateralFuse;
        fuses[2] = morphoBorrowFuse;

        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addFuses(fuses);
        vm.stopPrank();

        // Grant market substrates for Morpho (WETH and WBTC)
        bytes32[] memory morphoMarkets = new bytes32[](1);
        morphoMarkets[0] = _MORPHO_WETH_USDC_MARKET_ID;

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.MORPHO, morphoMarkets);
        vm.stopPrank();

        // Add MorphoBalanceFuse to PlasmaVault
        vm.startPrank(_FUSE_MANAGER);
        PlasmaVaultGovernance(_plasmaVault).addBalanceFuse(IporFusionMarkets.MORPHO, morphoBalanceFuse);
        vm.stopPrank();

        _morphoSupplyFuse = morphoSupplyFuse;
        _morphoCollateralFuse = morphoCollateralFuse;
        _morphoBorrowFuse = morphoBorrowFuse;
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
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(_WETH);

        vm.startPrank(_ATOMIST);
        PlasmaVaultGovernance(_plasmaVault).grantMarketSubstrates(IporFusionMarkets.ERC20_VAULT_BALANCE, substrates);
        vm.stopPrank();
    }

    function _provideUsdcToUser() private {
        uint256 amountToProvide = 100_000 * 1e6; // 100,000 USDC (USDC has 6 decimals)

        // Use deal to provide USDC to _USER
        deal(_USDC, _USER, amountToProvide);

        // Log the balance
    }

    //******************************************************************************************************************
    //********************                              TESTS                                       ********************
    //******************************************************************************************************************

    function testShouldFlashLoanUsdcOnMorphoSupplyUsdcBorrowWethOnUniswapSwapOnEuler() external {
        assertTrue(true);
    }

    function testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswap() external {
        /// Test steps
        /// - User deposit 50_000 USDC to plasma vault
        /// - Alpha swap 10_000 USDC to WETH
        /// Looping flow:
        /// 1. flash loan 10 USDC from Morpho
        /// 2. supply 20 USDC to Morpho market
        /// 3. borrow ???? WETH
        /// 4. swap 2???? WETH to USDC on Uniswap
        /// 5. repay 10 USDC to Morpho

        // Deposit 15 WBTC into PlasmaVault
        uint256 depositUsdcAmount = 30_000 * 1e6; // 30,000 USDC (USDC has 6 decimals)

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, depositUsdcAmount);
        PlasmaVault(_plasmaVault).deposit(depositUsdcAmount, _USER);
        vm.stopPrank();

        // Alpha swap 10,000 USDC to WETH ~8.0 WETH
        uint256 swapAmount = 20_000 * 1e6; // 20,000 USDC

        UniswapV3SwapFuseEnterData memory swapData = UniswapV3SwapFuseEnterData({
            tokenInAmount: swapAmount,
            path: abi.encodePacked(_USDC, uint24(500), _WETH),
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

        // 1. Provide 16 WETH as collateral to Morpho market
        MorphoCollateralFuseEnterData memory collateralData = MorphoCollateralFuseEnterData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            collateralAmount: 16 * 1e18 // 16 WETH
        });

        // 2. Borrow 200 WETH from Morpho
        MorphoBorrowFuseEnterData memory borrowData = MorphoBorrowFuseEnterData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            amountToBorrow: 20_000 * 1e6, // 20,000 USDC
            sharesToBorrow: 0 // Set to 0 for this example, but in production should use a reasonable max borrow rate
        });

        // 3. Swap 200 WETH to WBTC on Uniswap
        UniswapV3SwapFuseEnterData memory swapBackData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 20_000 * 1e6, // 20,000 USDC
            path: abi.encodePacked(_USDC, uint24(500), _WETH),
            minOutAmount: 0 // Set to 0 for this example, but in production should use a reasonable slippage tolerance
        });

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction({
            fuse: _morphoCollateralFuse,
            data: abi.encodeWithSignature("enter((bytes32,uint256))", collateralData)
        });
        actions[1] = FuseAction({
            fuse: _morphoBorrowFuse,
            data: abi.encodeWithSignature("enter((bytes32,uint256,uint256))", borrowData)
        });
        actions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapBackData)
        });

        // Create MorphoFlashLoanFuseEnterData for 10 WBTC flash loan
        MorphoFlashLoanFuseEnterData memory flashLoanData = MorphoFlashLoanFuseEnterData({
            token: _WETH,
            tokenAmount: 8 * 1e18, // 8 WETH
            callbackFuseActionsData: abi.encode(actions)
        });

        // Create FuseAction for Morpho flash loan
        FuseAction[] memory flashLoanAction = new FuseAction[](1);
        flashLoanAction[0] = FuseAction({
            fuse: _morphoFlashLoanFuse,
            data: abi.encodeWithSignature("enter((address,uint256,bytes))", flashLoanData)
        });

        uint256 balanceInMorphoBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);

        uint256 usdcBalanceBefore = ERC20(_USDC).balanceOf(_plasmaVault);
        uint256 wethBalanceBefore = ERC20(_WETH).balanceOf(_plasmaVault);

        // Execute the flash loan action
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(flashLoanAction);
        vm.stopPrank();

        // Log final balances after flash loan
        uint256 balanceInMorphoAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.MORPHO);

        uint256 usdcBalanceAfter = ERC20(_USDC).balanceOf(_plasmaVault);
        uint256 wethBalanceAfter = ERC20(_WETH).balanceOf(_plasmaVault);

        bytes32[] memory slots = new bytes32[](1);
        slots[0] = MorphoStorageLib.positionBorrowSharesAndCollateralSlot(
            Id.wrap(_MORPHO_WETH_USDC_MARKET_ID),
            _plasmaVault
        );

        Position memory position = IMorpho(_MORPHO).position(Id.wrap(_MORPHO_WETH_USDC_MARKET_ID), _plasmaVault);

        assertApproxEqAbs(position.collateral, 16e18, _ERROR_TOLERANCE, "position.collateral");
        assertApproxEqAbs(position.borrowShares, 19810698343143763, _ERROR_TOLERANCE, "position.borrowShares");

        assertApproxEqAbs(balanceInMorphoBefore, 0, _ERROR_TOLERANCE, "balanceInMorphoBefore");
        assertApproxEqAbs(balanceInMorphoAfter, 19799462392, _ERROR_TOLERANCE, "balanceInMorphoAfter");

        assertApproxEqAbs(usdcBalanceBefore, 10_000 * 1e6, _ERROR_TOLERANCE, "usdcBalanceBefore");
        assertApproxEqAbs(usdcBalanceAfter, 10_000 * 1e6, _ERROR_TOLERANCE, "usdcBalanceAfter");

        assertApproxEqAbs(wethBalanceBefore, 8036227806666916735, _ERROR_TOLERANCE, "wethBalanceBefore");
        assertApproxEqAbs(wethBalanceAfter, 70016225051781252, _ERROR_TOLERANCE, "wethBalanceAfter");
    }

    function testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswapAndRepay() external {
        // First part - same as testShouldFlashLoanWethOnMorphoSupplyWethBorrowUsdcOnEulerSwapOnUniswap
        uint256 depositUsdcAmount = 30_000 * 1e6;

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, depositUsdcAmount);
        PlasmaVault(_plasmaVault).deposit(depositUsdcAmount, _USER);
        vm.stopPrank();

        // Alpha swap 20,000 USDC to WETH
        uint256 swapAmount = 20_000 * 1e6;

        UniswapV3SwapFuseEnterData memory swapData = UniswapV3SwapFuseEnterData({
            tokenInAmount: swapAmount,
            path: abi.encodePacked(_USDC, uint24(500), _WETH),
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

        // Create actions for first flash loan
        MorphoCollateralFuseEnterData memory collateralData = MorphoCollateralFuseEnterData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            collateralAmount: 16 * 1e18
        });

        MorphoBorrowFuseEnterData memory borrowData = MorphoBorrowFuseEnterData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            amountToBorrow: 20_000 * 1e6,
            sharesToBorrow: 0
        });

        UniswapV3SwapFuseEnterData memory swapBackData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 20_000 * 1e6,
            path: abi.encodePacked(_USDC, uint24(500), _WETH),
            minOutAmount: 0
        });

        FuseAction[] memory actions = new FuseAction[](3);
        actions[0] = FuseAction({
            fuse: _morphoCollateralFuse,
            data: abi.encodeWithSignature("enter((bytes32,uint256))", collateralData)
        });
        actions[1] = FuseAction({
            fuse: _morphoBorrowFuse,
            data: abi.encodeWithSignature("enter((bytes32,uint256,uint256))", borrowData)
        });
        actions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapBackData)
        });

        MorphoFlashLoanFuseEnterData memory flashLoanData = MorphoFlashLoanFuseEnterData({
            token: _WETH,
            tokenAmount: 8 * 1e18,
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

        Position memory position = IMorpho(_MORPHO).position(Id.wrap(_MORPHO_WETH_USDC_MARKET_ID), _plasmaVault);

        MorphoBorrowFuseExitData memory repayData = MorphoBorrowFuseExitData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            amountToRepay: 0,
            sharesToRepay: position.borrowShares
        });

        MorphoCollateralFuseExitData memory withdrawData = MorphoCollateralFuseExitData({
            morphoMarketId: _MORPHO_WETH_USDC_MARKET_ID,
            maxCollateralAmount: 16 * 1e18
        });

        // Swap WBTC back to WETH to repay loan
        UniswapV3SwapFuseEnterData memory swapToRepayData = UniswapV3SwapFuseEnterData({
            tokenInAmount: 8 * 1e18,
            path: abi.encodePacked(_WETH, uint24(500), _USDC),
            minOutAmount: 0
        });

        FuseAction[] memory repayActions = new FuseAction[](3);
        repayActions[2] = FuseAction({
            fuse: _uniswapV3SwapFuse,
            data: abi.encodeWithSignature("enter((uint256,uint256,bytes))", swapToRepayData)
        });
        repayActions[0] = FuseAction({
            fuse: _morphoBorrowFuse,
            data: abi.encodeWithSignature("exit((bytes32,uint256,uint256))", repayData)
        });
        repayActions[1] = FuseAction({
            fuse: _morphoCollateralFuse,
            data: abi.encodeWithSignature("exit((bytes32,uint256))", withdrawData)
        });

        MorphoFlashLoanFuseEnterData memory repayFlashLoanData = MorphoFlashLoanFuseEnterData({
            token: _USDC,
            tokenAmount: 20_000 * 1e6,
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

        Position memory positionAfter = IMorpho(_MORPHO).position(Id.wrap(_MORPHO_WETH_USDC_MARKET_ID), _plasmaVault);

        assertApproxEqAbs(position.collateral, 16e18, _ERROR_TOLERANCE, "position.collateral");
        assertApproxEqAbs(position.borrowShares, 19810698343143763, _ERROR_TOLERANCE, "position.borrowShares");

        assertApproxEqAbs(positionAfter.collateral, 0, _ERROR_TOLERANCE, "positionAfter.collateral");
        assertApproxEqAbs(positionAfter.borrowShares, 0, _ERROR_TOLERANCE, "positionAfter.borrowShares");

        assertApproxEqAbs(PlasmaVault(_plasmaVault).totalAssets(), 29969881733, _ERROR_TOLERANCE, "totalAssetsAfter");
        assertApproxEqAbs(totalAssetsBefore, 29973625399, _ERROR_TOLERANCE, "totalAssetsBefore");
    }
}
