// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMorpho} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";
import {MorphoBlueSupplyWithCallBackDataFuse, MorphoBlueSupplyFuseEnterData} from "../../contracts/fuses/morphoBlue/MorphoBlueSupplyWithCallBackDataFuse.sol";
import {MorphoBlueBalanceFuse} from "../../contracts/fuses/morphoBlue/MorphoBlueBalanceFuse.sol";
import {MarketSubstratesConfig, FeeConfig, MarketBalanceFuseConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {InitializationData} from "../../contracts/managers/access/IporFusionAccessManagerInitializationLib.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, PlasmaVaultInitData, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CallbackHandlerMorpho} from "../../contracts/callback_handlers/CallbackHandlerMorpho.sol";

import {IporPlasmaVault} from "../../contracts/vaults/IporPlasmaVault.sol";

contract PlasmaVaultCallbackHandler is Test {
    address private constant _AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address private constant _ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;

    address private constant _AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 private constant _AAVE_V3_MARKET_ID = 1;

    address private constant _COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 private constant _COMPOUND_V3_MARKET_ID = 2;

    address private constant _DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    IMorpho private constant _MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    // sDAI/DAI
    uint256 private constant _MORPHO_BLUE_MARKET_ID = 3;
    bytes32 private constant _MARKET_ID_BYTES32 = 0xb1eac1c0f3ad13fb45b01beac8458c055c903b1bff8cb882346635996a774f77;

    PriceOracleMiddleware private _priceOracleMiddlewareProxy;
    MorphoBlueBalanceFuse private _morphoBlueBalanceFuse;

    address private _accessManager;
    address private _plasmaVault;
    AaveV3SupplyFuse private _supplyFuseAaveV3;
    MorphoBlueSupplyWithCallBackDataFuse private _morphoBlueFuse;
    CompoundV3SupplyFuse private _supplyFuseCompoundV3;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20432470);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        _priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );

        MarketSubstratesConfig[] memory marketConfigs = _setupMarketConfigs();
        MarketBalanceFuseConfig[] memory balanceFuses = _setupBalanceFuses();
        FeeConfig memory feeConfig = _setupFeeConfig();

        address[] memory alphas = new address[](1);
        alphas[0] = address(this);

        _createAccessManager();

        _plasmaVault = address(
            new IporPlasmaVault(
                PlasmaVaultInitData(
                    "TEST PLASMA VAULT",
                    "TPLASMA",
                    _DAI,
                    address(_priceOracleMiddlewareProxy),
                    alphas,
                    marketConfigs,
                    _setupFuses(),
                    balanceFuses,
                    feeConfig,
                    _accessManager
                )
            )
        );

        _initAccessManager();
        _setuCallbackCals();
    }

    function _setuCallbackCals() private {
        CallbackHandlerMorpho callbackHandlerMorpho = new CallbackHandlerMorpho();
        PlasmaVault(_plasmaVault).updateCallbackHandler(
            address(callbackHandlerMorpho),
            address(_MORPHO),
            CallbackHandlerMorpho.onMorphoSupply.selector
        );
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _morphoBlueFuse = new MorphoBlueSupplyWithCallBackDataFuse(_MORPHO_BLUE_MARKET_ID);
        _supplyFuseAaveV3 = new AaveV3SupplyFuse(_AAVE_V3_MARKET_ID, _AAVE_POOL, _ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3);
        _supplyFuseCompoundV3 = new CompoundV3SupplyFuse(_COMPOUND_V3_MARKET_ID, _COMET_V3_USDC);

        fuses = new address[](3);
        fuses[0] = address(_morphoBlueFuse);
        fuses[1] = address(_supplyFuseAaveV3);
        fuses[2] = address(_supplyFuseCompoundV3);
    }

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](3);
        bytes32[] memory morphoBlue = new bytes32[](1);
        morphoBlue[0] = _MARKET_ID_BYTES32;
        marketConfigs[0] = MarketSubstratesConfig(_MORPHO_BLUE_MARKET_ID, morphoBlue);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);
        marketConfigs[1] = MarketSubstratesConfig(_COMPOUND_V3_MARKET_ID, assets);
        marketConfigs[2] = MarketSubstratesConfig(_AAVE_V3_MARKET_ID, assets);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](3);

        balanceFuses[0] = MarketBalanceFuseConfig(
            _MORPHO_BLUE_MARKET_ID,
            address(new MorphoBlueBalanceFuse(_MORPHO_BLUE_MARKET_ID, address(_priceOracleMiddlewareProxy)))
        );
        balanceFuses[1] = MarketBalanceFuseConfig(
            _AAVE_V3_MARKET_ID,
            address(
                new AaveV3BalanceFuse(
                    _AAVE_V3_MARKET_ID,
                    _AAVE_PRICE_ORACLE_MAINNET,
                    _ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
                )
            )
        );
        balanceFuses[2] = MarketBalanceFuseConfig(
            _COMPOUND_V3_MARKET_ID,
            address(new CompoundV3BalanceFuse(_COMPOUND_V3_MARKET_ID, _COMET_V3_USDC))
        );
    }

    /// @dev Setup default  fee configuration for the PlasmaVault
    function _setupFeeConfig() private view returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfig({
            performanceFeeManager: address(this),
            performanceFeeInPercentage: 0,
            managementFeeManager: address(this),
            managementFeeInPercentage: 0
        });
    }

    function _createAccessManager() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        _accessManager = address(RoleLib.createAccessManager(usersToRoles, vm));
    }

    function _initAccessManager() private {
        IporFusionAccessManager accessManager = IporFusionAccessManager(_accessManager);
        address[] memory initAddress = new address[](1);
        initAddress[0] = address(this);

        DataForInitialization memory data = DataForInitialization({
            admins: initAddress,
            owners: initAddress,
            atomists: initAddress,
            alphas: initAddress,
            whitelist: initAddress,
            guardians: initAddress,
            fuseManagers: initAddress,
            performanceFeeManagers: initAddress,
            managementFeeManagers: initAddress,
            claimRewards: initAddress,
            transferRewardsManagers: initAddress,
            configInstantWithdrawalFusesManagers: initAddress,
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(this),
                feeManager: address(this)
            })
        });

        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        accessManager.initialize(initializationData);
    }

    function testShouldDepositToAaveACompoundAfterDepositToMorphoBlue() public {
        //given
        address userOne = address(this);
        uint256 amount = 100_000e18;
        deal(_DAI, address(userOne), amount);

        ERC20(_DAI).approve(_plasmaVault, 3 * amount);

        PlasmaVault(_plasmaVault).deposit(amount, userOne);

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(_USDC).transfer(_plasmaVault, 1_000e6);

        FuseAction[] memory callbackCalls = new FuseAction[](2);
        callbackCalls[0] = FuseAction(
            address(_supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: _USDC, amount: 10e6, userEModeCategoryId: 1e6}))
            )
        );

        callbackCalls[1] = FuseAction(
            address(_supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: _USDC, amount: 10e6}))
            )
        );

        bytes memory callbackCallsBytes = abi.encode(callbackCalls);

        FuseAction[] memory morphoCalls = new FuseAction[](1);
        morphoCalls[0] = FuseAction(
            address(_morphoBlueFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    MorphoBlueSupplyFuseEnterData({
                        morphoBlueMarketId: _MARKET_ID_BYTES32,
                        amount: 100e18,
                        callbackData: callbackCallsBytes
                    })
                )
            )
        );

        uint256 aaveMarketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(_AAVE_V3_MARKET_ID);
        uint256 compoundMarketBalanceBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(_COMPOUND_V3_MARKET_ID);
        uint256 morphoMarketCompoundBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(_MORPHO_BLUE_MARKET_ID);

        //when
        PlasmaVault(_plasmaVault).execute(morphoCalls);

        // then

        uint256 aaveMarketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(_AAVE_V3_MARKET_ID);
        uint256 compoundMarketBalanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(_COMPOUND_V3_MARKET_ID);
        uint256 morphoMarketCompoundAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(_MORPHO_BLUE_MARKET_ID);

        assertEq(aaveMarketBalanceBefore, 0, "aaveMarketBalanceBefore");
        assertGt(aaveMarketBalanceAfter, 0, "aaveMarketBalanceAfter");
        assertEq(compoundMarketBalanceBefore, 0, "compoundMarketBalanceBefore");
        assertGt(compoundMarketBalanceAfter, 0, "compoundMarketBalanceAfter");
        assertEq(morphoMarketCompoundBefore, 0, "morphoMarketCompoundBefore");
        assertGt(morphoMarketCompoundAfter, 0, "morphoMarketCompoundAfter");
    }
}