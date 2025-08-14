// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {LiquityTroveFuse, LiquityTroveEnterData, LiquityTroveExitData} from "../../../contracts/fuses/liquity/LiquityTroveFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LiquityTroveBalanceFuse} from "../../../contracts/fuses/liquity/LiquityTroveBalanceFuse.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MarketSubstratesConfig, MarketBalanceFuseConfig, FeeConfig, FuseAction, PlasmaVault, PlasmaVaultInitData} from "../../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {ZeroBalanceFuse} from "../../../contracts/fuses/ZeroBalanceFuse.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
contract LiquityTroveFuseTest is Test {
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant RETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address internal constant BOLD = 0x6440f144b7e50D6a8439336510312d2F54beB01D;

    address internal constant ETH_REGISTRY = 0x20F7C9ad66983F6523a0881d0f82406541417526;
    address internal constant WSTETH_REGISTRY = 0x8d733F7ea7c23Cbea7C613B6eBd845d46d3aAc54;
    address internal constant RETH_REGISTRY = 0x6106046F031a22713697e04C08B330dDaf3e8789;

    address private plasmaVault;
    address private accessManager;
    address private priceOracle;
    ERC20BalanceFuse private erc20BalanceFuse;
    address private balanceFuse;
    LiquityTroveFuse private _liquityTroveFuse;


    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22631293);
        address[] memory assets = new address[](4);
        assets[0] = BOLD;
        assets[1] = WETH;
        assets[2] = WSTETH;
        assets[3] = RETH;
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));

        address[] memory priceFeeds = new address[](4);
        priceFeeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // we use USDC price feed for BOLD
        priceFeeds[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WETH price feed
        priceFeeds[2] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WSTETH price feed
        priceFeeds[3] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // RETH price feed

        implementation.setAssetsPricesSources(assets, priceFeeds);
        priceOracle = address(implementation);


        PlasmaVaultInitData memory initData = PlasmaVaultInitData(
                "TEST PLASMA VAULT",
                "pvWETH",
                WETH,
                priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            );
        
        plasmaVault = address(new PlasmaVault(initData));

        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            plasmaVault,
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.LIQUITY_V2_TROVE;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Liquity -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);

    }

    function testLiquityTroveShouldEnter() public {
        LiquityTroveEnterData memory enterData = LiquityTroveEnterData({
            registry: ETH_REGISTRY,
            newIndex: 1,
            collAmount: 2000 * 1e18,
            boldAmount: 2000 * 1e18,
            upperHint: 0,
            lowerHint: 0,
            annualInterestRate: 1e16,
            maxUpfrontFee: 4e18
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(_liquityTroveFuse),
            abi.encodeWithSignature("enter((address,uint256,uint256,uint256,uint256,uint256,uint256,uint256))", enterData)
        );

        deal(WETH, address(this), 200000 * 1e18);
        ERC20(WETH).approve(plasmaVault, 200000 * 1e18);
        PlasmaVault(plasmaVault).deposit(200000 * 1e18, address(this));
        PlasmaVault(plasmaVault).execute(enterCalls);
    }

    function testLiquityTroveShouldExit() public {
        testLiquityTroveShouldEnter();

        uint256[] memory ownerIndexes = new uint256[](1);
        ownerIndexes[0] = 1;
        LiquityTroveExitData memory exitData = LiquityTroveExitData(
            ETH_REGISTRY,
            ownerIndexes
        );
        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(_liquityTroveFuse),
            abi.encodeWithSignature("exit((address,uint256[]))", exitData)
        );

        // deal enough BOLD to pay for the entire debt
        deal(BOLD, plasmaVault, 3 * 1e22);
        PlasmaVault(plasmaVault).execute(exitCalls);
    }

    function _setupMarketConfigs() private pure returns (MarketSubstratesConfig[] memory marketConfigs_) {
        marketConfigs_ = new MarketSubstratesConfig[](1);

        bytes32[] memory registries = new bytes32[](3);
        registries[0] = PlasmaVaultConfigLib.addressToBytes32(ETH_REGISTRY);
        registries[1] = PlasmaVaultConfigLib.addressToBytes32(WSTETH_REGISTRY);
        registries[2] = PlasmaVaultConfigLib.addressToBytes32(RETH_REGISTRY);

        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.LIQUITY_V2_TROVE, registries);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        _liquityTroveFuse = new LiquityTroveFuse(IporFusionMarkets.LIQUITY_V2_TROVE);

        fuses = new address[](1);
        fuses[0] = address(_liquityTroveFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = address(new LiquityTroveBalanceFuse(IporFusionMarkets.LIQUITY_V2_TROVE));
        ZeroBalanceFuse zeroBalance = new ZeroBalanceFuse(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](3);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.LIQUITY_V2_TROVE, balanceFuse);
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.UNIVERSAL_TOKEN_SWAPPER, address(zeroBalance));
        balanceFuses_[2] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
    }

    function _setupFeeConfig() private returns (FeeConfig memory feeConfig_) {
        feeConfig_ = FeeConfigHelper.createZeroFeeConfig();
    }

    function _createAccessManager() private returns (address accessManager_) {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        address[] memory alphas = new address[](1);
        alphas[0] = address(this);
        usersToRoles.alphas = alphas;
        accessManager_ = address(RoleLib.createAccessManager(usersToRoles, 0, vm));
        accessManager = accessManager_;
    }

    function _setupRoles() private {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = address(this);
        usersToRoles.atomist = address(this);
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, plasmaVault, IporFusionAccessManager(accessManager),
            address(0));
    }
}