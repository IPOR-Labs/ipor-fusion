// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {PlasmaVault, PlasmaVaultInitData, MarketBalanceFuseConfig, FeeConfig, MarketSubstratesConfig, FuseAction} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {IporFusionAccessManagerInitializerLibV1, DataForInitialization, PlasmaVaultAddress, InitializationData} from "../../contracts/vaults/initializers/IporFusionAccessManagerInitializerLibV1.sol";
import {IporFusionMarkets} from "../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultConfigLib} from "../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {IPool} from "../../contracts/fuses/aave_v3/ext/IPool.sol";
import {IAavePriceOracle} from "../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {IComet} from "../../contracts/fuses/compound_v3/ext/IComet.sol";
import {FeeConfigHelper} from "../test_helpers/FeeConfigHelper.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";

contract PlasmaVaultUpdateMarketsBalances is Test {
    address private constant _ATOMIST = address(1111111);
    address private constant _ALPHA = address(2222222);
    address private constant _USER = address(12121212);
    address private constant _USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address private constant _USDC_HOLDER = 0x77EC2176824Df1145425EB51b3C88B9551847667;

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    address public constant ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;

    uint256 private constant _SUPPLY_AAVE = 1_000e6;
    uint256 private constant _SUPPLY_COMPOUND = 2_000e6;
    uint256 private constant _DEPOSIT_AMOUNT = 10_000e6;

    address private _plasmaVault;
    address private _priceOracle;
    address private _accessManager;
    address private _aaveFuse;
    address private _compoundFuse;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 20818075);
        vm.prank(_USDC_HOLDER);
        ERC20(_USDC).transfer(_USER, 20_000e6);
        _createAccessManager();
        _createPriceOracle();
        _createPlasmaVault();
        _initAccessManager();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(_plasmaVault, _DEPOSIT_AMOUNT);
        PlasmaVault(_plasmaVault).deposit(_DEPOSIT_AMOUNT, _USER);
        vm.stopPrank();

        _supplyToAveAndCompound();
    }

    function _supplyToAveAndCompound() private {
        FuseAction[] memory calls = new FuseAction[](2);
        calls[0] = FuseAction(
            address(_aaveFuse),
            abi.encodeWithSignature(
                "enter((address,uint256,uint256))",
                AaveV3SupplyFuseEnterData({asset: _USDC, amount: _SUPPLY_AAVE, userEModeCategoryId: 1e6})
            )
        );
        calls[1] = FuseAction(
            address(_compoundFuse),
            abi.encodeWithSignature(
                "enter((address,uint256))",
                CompoundV3SupplyFuseEnterData({asset: _USDC, amount: _SUPPLY_COMPOUND})
            )
        );
        vm.startPrank(_ALPHA);
        PlasmaVault(_plasmaVault).execute(calls);
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

    function _setupMarketConfigs() private returns (MarketSubstratesConfig[] memory marketConfigs) {
        marketConfigs = new MarketSubstratesConfig[](2);
        bytes32[] memory substrates = new bytes32[](1);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(_USDC);

        marketConfigs[0] = MarketSubstratesConfig({marketId: IporFusionMarkets.AAVE_V3, substrates: substrates});

        marketConfigs[1] = MarketSubstratesConfig({
            marketId: IporFusionMarkets.COMPOUND_V3_USDC,
            substrates: substrates
        });
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses) {
        balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.COMPOUND_V3_USDC,
            fuse: address(new CompoundV3BalanceFuse(IporFusionMarkets.COMPOUND_V3_USDC, COMET_V3_USDC))
        });

        balanceFuses[1] = MarketBalanceFuseConfig({
            marketId: IporFusionMarkets.AAVE_V3,
            fuse: address(new AaveV3BalanceFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER))
        });
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig) {
        feeConfig = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createFuse() private returns (address[] memory) {
        address[] memory fuses = new address[](2);
        fuses[0] = address(new AaveV3SupplyFuse(IporFusionMarkets.AAVE_V3, ETHEREUM_AAVE_V3_POOL_ADDRESSES_PROVIDER));
        fuses[1] = address(new CompoundV3SupplyFuse(IporFusionMarkets.COMPOUND_V3_USDC, COMET_V3_USDC));
        _aaveFuse = fuses[0];
        _compoundFuse = fuses[1];
        return fuses;
    }

    function _createAccessManager() private {
        _accessManager = address(new IporFusionAccessManager(_ATOMIST, 0));
    }

    function _createPriceOracle() private {
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        _priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
        );
    }

    function _initAccessManager() private {
        address[] memory initAddress = new address[](3);
        initAddress[0] = address(this);
        initAddress[1] = _ATOMIST;
        initAddress[2] = _ALPHA;

        address[] memory whitelist = new address[](1);
        whitelist[0] = _USER;

        DataForInitialization memory data = DataForInitialization({
            isPublic: false,
            iporDaos: initAddress,
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
            plasmaVaultAddress: PlasmaVaultAddress({
                plasmaVault: _plasmaVault,
                accessManager: _accessManager,
                rewardsClaimManager: address(0),
                withdrawManager: address(0),
                feeManager: address(0),
                contextManager: address(0)
            })
        });
        InitializationData memory initializationData = IporFusionAccessManagerInitializerLibV1
            .generateInitializeIporPlasmaVault(data);
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).initialize(initializationData);
        vm.stopPrank();
    }

    function testShouldUpdateMarketsBalancesWhenHasRoleUpdateMarketsBalances() external {
        // given
        vm.startPrank(_ATOMIST);
        IporFusionAccessManager(_accessManager).grantRole(Roles.UPDATE_MARKETS_BALANCES_ROLE, _USER, 0);
        vm.stopPrank();

        // when
        uint256 updateMarketsBalances = PlasmaVault(_plasmaVault).updateMarketsBalances(new uint256[](0));

        // then
        assertEq(
            updateMarketsBalances,
            PlasmaVault(_plasmaVault).totalAssets(),
            "updateMarketsBalances should be equal to totalAssets"
        );
    }

    function testShouldRevertWhenHasNoRoleUpdateMarketsBalances() external {
        // given
        address randomUser = address(0x777);
        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", randomUser);

        // when
        vm.expectRevert(error);
        vm.startPrank(randomUser);
        PlasmaVault(_plasmaVault).updateMarketsBalances(new uint256[](0));
        vm.stopPrank();
    }

    function testShouldReturnTheSameValueAsTotalAssetsWhenEmptyArrayPass() external {
        uint256 totalAssets = PlasmaVault(_plasmaVault).totalAssets();
        uint256 updateMarketsBalances = PlasmaVault(_plasmaVault).updateMarketsBalances(new uint256[](0));
        uint256 balanceInAave = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceInCompound = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.COMPOUND_V3_USDC);

        assertGt(totalAssets, 0, "totalAssets should be greater than 0");
        assertEq(totalAssets, updateMarketsBalances, "totalAssets should be equal to updateMarketsBalances");
        assertApproxEqAbs(balanceInAave, _SUPPLY_AAVE, 1e6, "balanceInAave should be equal to 1_000e6");
        assertApproxEqAbs(balanceInCompound, _SUPPLY_COMPOUND, 1e6, "balanceInCompound should be equal to 2_000e6");
    }

    function testShouldUpdateAaveBalance() external {
        // given
        uint256 newAaveFunds = 500e6;
        uint256 newCompoundFunds = 700e6;

        uint256 balanceAaveBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), newAaveFunds);
        AAVE_POOL.supply(_USDC, newAaveFunds, _plasmaVault, 0);

        ERC20(_USDC).approve(address(COMET_V3_USDC), newCompoundFunds);
        IComet(COMET_V3_USDC).supplyTo(_plasmaVault, _USDC, newCompoundFunds);
        vm.stopPrank();

        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.AAVE_V3;

        // when
        uint256 updateMarketsBalances = PlasmaVault(_plasmaVault).updateMarketsBalances(markets);

        // then
        uint256 balanceAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqAbs(balanceAaveBefore, _SUPPLY_AAVE, 1e6, "balanceAaveBefore should be equal to 1_000e6");
        assertApproxEqAbs(
            balanceCompoundBefore,
            _SUPPLY_COMPOUND,
            1e6,
            "balanceCompoundBefore should be equal to 2_000e6"
        );
        assertApproxEqAbs(totalAssetsBefore, _DEPOSIT_AMOUNT, 1e6, "totalAssetsBefore should be equal to 3_000e6");

        assertApproxEqAbs(balanceAfter, _SUPPLY_AAVE + newAaveFunds, 1e6, "balanceAfter should be equal to 1_500e6");
        assertApproxEqAbs(
            balanceCompoundAfter,
            _SUPPLY_COMPOUND,
            1e6,
            "balanceCompoundAfter should be equal to 2_000e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            _DEPOSIT_AMOUNT + newAaveFunds,
            1e6,
            "totalAssetsAfter should be equal to 3_500e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            updateMarketsBalances,
            1e6,
            "totalAssetsAfter should be equal to updateMarketsBalances"
        );
    }

    function testShouldUpdateCompoundBalance() external {
        // given
        uint256 newAaveFunds = 500e6;
        uint256 newCompoundFunds = 700e6;

        uint256 balanceAaveBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), newAaveFunds);
        AAVE_POOL.supply(_USDC, newAaveFunds, _plasmaVault, 0);

        ERC20(_USDC).approve(address(COMET_V3_USDC), newCompoundFunds);
        IComet(COMET_V3_USDC).supplyTo(_plasmaVault, _USDC, newCompoundFunds);
        vm.stopPrank();

        uint256[] memory markets = new uint256[](1);
        markets[0] = IporFusionMarkets.COMPOUND_V3_USDC;

        // when
        uint256 updateMarketsBalances = PlasmaVault(_plasmaVault).updateMarketsBalances(markets);

        // then
        uint256 balanceAaveAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqAbs(balanceAaveBefore, _SUPPLY_AAVE, 1e6, "balanceAaveBefore should be equal to 1_000e6");
        assertApproxEqAbs(
            balanceCompoundBefore,
            _SUPPLY_COMPOUND,
            1e6,
            "balanceCompoundBefore should be equal to 2_000e6"
        );
        assertApproxEqAbs(totalAssetsBefore, _DEPOSIT_AMOUNT, 1e6, "totalAssetsBefore should be equal to 3_000e6");

        assertApproxEqAbs(balanceAaveAfter, _SUPPLY_AAVE, 1e6, "balanceAfter should be equal to 1_000e6");
        assertApproxEqAbs(
            balanceCompoundAfter,
            _SUPPLY_COMPOUND + newCompoundFunds,
            1e6,
            "balanceCompoundAfter should be equal to 2_700e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            _DEPOSIT_AMOUNT + newCompoundFunds,
            1e6,
            "totalAssetsAfter should be equal to 3_700e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            updateMarketsBalances,
            1e6,
            "totalAssetsAfter should be equal to updateMarketsBalances"
        );
    }

    function testShouldUpdateCompoundAndAaveBalance() external {
        // given
        uint256 newAaveFunds = 500e6;
        uint256 newCompoundFunds = 700e6;

        uint256 balanceAaveBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundBefore = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsBefore = PlasmaVault(_plasmaVault).totalAssets();

        vm.startPrank(_USER);
        ERC20(_USDC).approve(address(AAVE_POOL), newAaveFunds);
        AAVE_POOL.supply(_USDC, newAaveFunds, _plasmaVault, 0);

        ERC20(_USDC).approve(address(COMET_V3_USDC), newCompoundFunds);
        IComet(COMET_V3_USDC).supplyTo(_plasmaVault, _USDC, newCompoundFunds);
        vm.stopPrank();

        uint256[] memory markets = new uint256[](2);
        markets[0] = IporFusionMarkets.COMPOUND_V3_USDC;
        markets[1] = IporFusionMarkets.AAVE_V3;

        // when
        uint256 updateMarketsBalances = PlasmaVault(_plasmaVault).updateMarketsBalances(markets);

        // then
        uint256 balanceAaveAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(IporFusionMarkets.AAVE_V3);
        uint256 balanceCompoundAfter = PlasmaVault(_plasmaVault).totalAssetsInMarket(
            IporFusionMarkets.COMPOUND_V3_USDC
        );
        uint256 totalAssetsAfter = PlasmaVault(_plasmaVault).totalAssets();

        assertApproxEqAbs(balanceAaveBefore, _SUPPLY_AAVE, 1e6, "balanceAaveBefore should be equal to 1_000e6");
        assertApproxEqAbs(
            balanceCompoundBefore,
            _SUPPLY_COMPOUND,
            1e6,
            "balanceCompoundBefore should be equal to 2_000e6"
        );
        assertApproxEqAbs(totalAssetsBefore, _DEPOSIT_AMOUNT, 1e6, "totalAssetsBefore should be equal to 3_000e6");

        assertApproxEqAbs(
            balanceAaveAfter,
            _SUPPLY_AAVE + newAaveFunds,
            1e6,
            "balanceAfter should be equal to 1_500e6"
        );
        assertApproxEqAbs(
            balanceCompoundAfter,
            _SUPPLY_COMPOUND + newCompoundFunds,
            1e6,
            "balanceCompoundAfter should be equal to 2_700e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            _DEPOSIT_AMOUNT + newCompoundFunds + newAaveFunds,
            1e6,
            "totalAssetsAfter should be equal to 4_200e6"
        );
        assertApproxEqAbs(
            totalAssetsAfter,
            updateMarketsBalances,
            1e6,
            "totalAssetsAfter should be equal to updateMarketsBalances"
        );
    }

    function testShouldRevertWhenPassNotSupportedMarketId() external {
        // given
        uint256[] memory markets = new uint256[](1);
        markets[0] = 3;

        bytes memory error = abi.encodeWithSignature("AddressEmptyCode(address)", address(0));

        // when
        vm.expectRevert(error);
        PlasmaVault(_plasmaVault).updateMarketsBalances(markets);
    }

    function _extractMockInnerBalanceEvent(
        Vm.Log[] memory entries
    ) private view returns (address token, uint256 amount) {
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("MockInnerBalance(address,uint256)")) {
                (token, amount) = abi.decode(entries[i].data, (address, uint256));
                break;
            }
        }
    }
}
