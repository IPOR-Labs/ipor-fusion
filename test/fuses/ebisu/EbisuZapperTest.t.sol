// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {
    MarketSubstratesConfig,
    MarketBalanceFuseConfig,
    FeeConfig,
    FuseAction,
    PlasmaVault,
    PlasmaVaultInitData
} from "../../../contracts/vaults/PlasmaVault.sol";

import {
    EbisuZapperFuse,
    EbisuZapperFuseEnterData,
    EbisuZapperFuseExitData,
    ExitType
} from "../../../contracts/fuses/ebisu/EbisuZapperFuse.sol";

import {EbisuZapperBalanceFuse} from "../../../contracts/fuses/ebisu/EbisuZapperBalanceFuse.sol";
import {ITroveManager} from "../../../contracts/fuses/ebisu/ext/ITroveManager.sol";
import {ILeverageZapper} from "../../../contracts/fuses/ebisu/ext/ILeverageZapper.sol";
import {EbisuMathLibrary} from "../../../contracts/fuses/ebisu/EbisuMathLibrary.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC20BalanceFuse} from "../../../contracts/fuses/erc20/Erc20BalanceFuse.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultBase} from "../../../contracts/vaults/PlasmaVaultBase.sol";
import {PlasmaVaultConfigurator} from "../../utils/PlasmaVaultConfigurator.sol";
import {PlasmaVaultConfigLib} from "../../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {WithdrawManager} from "../../../contracts/managers/withdraw/WithdrawManager.sol";
import {IporFusionAccessManager} from "../../../contracts/managers/access/IporFusionAccessManager.sol";
import {IporFusionMarkets} from "../../../contracts/libraries/IporFusionMarkets.sol";
import {PlasmaVaultGovernance} from "../../../contracts/vaults/PlasmaVaultGovernance.sol";
import {FeeConfigHelper} from "../../test_helpers/FeeConfigHelper.sol";
import {RoleLib, UsersToRoles} from "../../RoleLib.sol";

import {
    EbisuZapperLeverUpFuse,
    EbisuLeverUpData
} from "../../../contracts/fuses/ebisu/EbisuZapperLeverUpFuse.sol";
import {
    EbisuZapperLeverDownFuse,
    EbisuLeverDownData
} from "../../../contracts/fuses/ebisu/EbisuZapperLeverDownFuse.sol";
import {WethEthAdapter} from "../../../contracts/fuses/ebisu/WethEthAdapter.sol";

interface EbisuPriceFeed {
    function lastGoodPrice() external view returns (uint256);
}

interface EBUSDPriceFeed {
    function latestRound() external view returns (uint256);
}

contract EbisuZapperTest is Test {
    // Gas Asset
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Borrow Asset
    address internal constant EBUSD = 0x09fD37d9AA613789c517e76DF1c53aEce2b60Df4; // debt token
    // Collateral Assets
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee; // collateral token
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address internal constant LBTC = 0x8236a87084f8B84306f72007F36F2618A5634494;
    // Zapper Addresses
    address internal constant WEETH_ZAPPER = 0x54965fD4Dacbc5Ab969C2F52E866c1a37AD66923;
    address internal constant SUSDE_ZAPPER = 0x10C14374104f9FC2dAE4b38F945ff8a52f48151d;
    address internal constant WBTC_ZAPPER = 0x175a17755ea596875CB3c996D007072C3f761F6B;
    address internal constant LBTC_ZAPPER = 0xe32E9aB36558e5341A4C05FD635Db4Ba1F3F51cF;
    // Address Registries
    address internal constant WEETH_REGISTRY = 0x329a7BAA50BB43A6149AF8C9cF781876b6Fd7B3A;
    address internal constant SUSDE_REGISTRY = 0x411ED8575a1e3822Bbc763DC578dd9bFAF526C1f;
    address internal constant WBTC_REGISTRY = 0x0CAc6a40EE0D35851Fd6d9710C5180F30B494350;
    address internal constant LBTC_REGISTRY = 0x7f034988AF49248D3d5bD81a2CE76ED4a3006243;

    PlasmaVault private plasmaVault;
    EbisuZapperFuse private zapperFuse;
    EbisuZapperLeverUpFuse private leverUpFuse;
    EbisuZapperLeverDownFuse private leverDownFuse;
    EbisuZapperBalanceFuse private balanceFuse;
    ERC20BalanceFuse private erc20BalanceFuse;
    WethEthAdapter private wethEthAdapter;

    address private accessManager;
    address private priceOracle;

    // ETH gas compensation constant from zapper (keep in sync with fuse)
    uint256 private constant ETH_GAS_COMPENSATION = 0.0375 ether;

    receive() external payable {}

    function setUp() public {
        // block height -> 23277699 | Sep-02-2025 08:23:23 PM +UTC
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 23277699);
        // assets
        address[] memory assets = new address[](5);
        assets[0] = EBUSD; // borrowed
        assets[1] = WEETH; // collateral
        assets[2] = SUSDE; // collateral
        assets[3] = WBTC;  // collateral
        assets[4] = LBTC;  // collateral

        // price feeders
        address[] memory priceFeeds = new address[](5);
        priceFeeds[0] = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // EBUSD (USD feed)
        priceFeeds[1] = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // WEETH ~ ETH
        priceFeeds[2] = 0xFF3BC18cCBd5999CE63E788A1c250a88626aD099; // sUSDe
        priceFeeds[3] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // WBTC
        priceFeeds[4] = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c; // LBTC (reuse WBTC)

        // instantiate oracle middleware
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);
        implementation.initialize(address(this));
        // then set assets prices sources on the oracle middleware
        implementation.setAssetsPricesSources(assets, priceFeeds);
        priceOracle = address(implementation);

        // create plasma vault in a single step
        plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "TEST WEETH PLASMA VAULT",
                "pvWEETH",
                WEETH,
                priceOracle,
                _setupFeeConfig(),
                _createAccessManager(),
                address(new PlasmaVaultBase()),
                address(new WithdrawManager(accessManager))
            )
        );

        // deploy adapter (must be whitelisted)
        wethEthAdapter = new WethEthAdapter(address(plasmaVault), WETH);

        // setup plasma vault
        PlasmaVaultConfigurator.setupPlasmaVault(
            vm,
            address(this),
            address(plasmaVault),
            _setupFuses(),
            _setupBalanceFuses(),
            _setupMarketConfigs()
        );

        // setup dependency balance graph for the Ebisu Zapper
        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = IporFusionMarkets.EBISU;

        uint256[] memory dependence = new uint256[](1);
        dependence[0] = IporFusionMarkets.ERC20_VAULT_BALANCE;

        uint256[][] memory dependenceMarkets = new uint256[][](1);
        dependenceMarkets[0] = dependence; // Ebisu -> ERC20_VAULT_BALANCE

        PlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, dependenceMarkets);
    }

    function testShouldEnterToEbisuZapper() public {
        // given
        EbisuZapperFuseEnterData memory enterData = EbisuZapperFuseEnterData({
            zapper: WEETH_ZAPPER,
            registry: WEETH_REGISTRY,
            collAmount: 10 * 1e18,        // 10 WEETH
            ebusdAmount: 2345 * 1e18,     // debt
            upperHint: 0,
            lowerHint: 0,
            flashLoanAmount: 1 * 1e17,    // 0.1 ETH
            annualInterestRate: 20 * 1e16, // 20%
            maxUpfrontFee: 4 * 1e18,
            weth: WETH,
            wethEthAdapter: address(wethEthAdapter),
            wethForGas: ETH_GAS_COMPENSATION
        });

        FuseAction[] memory enterCalls = new FuseAction[](1);
        enterCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "enter((address,address,uint256,uint256,uint256,uint256,uint256,uint256,uint256,address,address,uint256))",
                enterData
            )
        );

        deal(WEETH, address(this), 10 * 1e18);
        ERC20(WEETH).approve(address(plasmaVault), 10 * 1e18);
        plasmaVault.deposit(10 * 1e18, address(this));

        // send to vault rather than deal
        deal(WETH, address(this), ETH_GAS_COMPENSATION);
        ERC20(WETH).transfer(address(plasmaVault), ETH_GAS_COMPENSATION);

        // when
        plasmaVault.execute(enterCalls);

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(wethEthAdapter), address(plasmaVault), WEETH_ZAPPER, 1);

        // Inspect trove state
        ITroveManager troveManager = ITroveManager(ILeverageZapper(WEETH_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then
        assertGe(troveData.entireDebt, enterData.ebusdAmount);
        assertLt(troveData.entireDebt, (enterData.ebusdAmount * 101) / 100);
        assertEq(troveData.entireColl, enterData.collAmount + enterData.flashLoanAmount);
    }

    function testShouldExitToETHFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // Send enough EBUSD to the Vault to pay the whole debt
        deal(EBUSD, address(this), 3000 * 1e18);
        ERC20(EBUSD).transfer(address(plasmaVault), 3000 * 1e18);

        EbisuZapperFuseExitData memory exitData = EbisuZapperFuseExitData({
            zapper: WEETH_ZAPPER,
            flashLoanAmount: 0,
            minExpectedCollateral: 0,
            exitType: ExitType.ETH,
            weth: WETH,
            wethEthAdapter: address(wethEthAdapter)
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "exit((address,uint256,uint256,uint8,address,address))",
                exitData
            )
        );

        // when
        plasmaVault.execute(exitCalls);

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(wethEthAdapter), address(plasmaVault), WEETH_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(WEETH_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then 
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);
    }

    function testShouldExitFromCollateralFromEbisuZapper() public {
        // given
        testShouldEnterToEbisuZapper();

        // Send enough EBUSD to the Vault to repay
        deal(EBUSD, address(this), 3000 * 1e18);
        ERC20(EBUSD).transfer(address(plasmaVault), 3000 * 1e18);

        EbisuZapperFuseExitData memory exitData = EbisuZapperFuseExitData({
            zapper: WEETH_ZAPPER,
            flashLoanAmount: 1 * 1e18,
            minExpectedCollateral: 6 * 1e16,
            exitType: ExitType.COLLATERAL,
            weth: WETH,
            wethEthAdapter: address(wethEthAdapter)
        });

        FuseAction[] memory exitCalls = new FuseAction[](1);
        exitCalls[0] = FuseAction(
            address(zapperFuse),
            abi.encodeWithSignature(
                "exit((address,uint256,uint256,uint8,address,address))",
                exitData
            )
        );

        // when
        plasmaVault.execute(exitCalls);

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(wethEthAdapter), address(plasmaVault), WEETH_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(WEETH_ZAPPER).troveManager());
        ITroveManager.LatestTroveData memory troveData = troveManager.getLatestTroveData(troveId);

        // then
        assertEq(troveData.entireColl, 0);
        assertEq(troveData.entireDebt, 0);
    }

    function testLeverUpEffectsEbisu() public {
        // given
        testShouldEnterToEbisuZapper();

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(wethEthAdapter), address(plasmaVault), WEETH_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(WEETH_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);
        uint256 initialDebt = initialData.entireDebt;
        uint256 initialColl = initialData.entireColl;

        EbisuLeverUpData memory leverUpData = EbisuLeverUpData({
            zapper: WEETH_ZAPPER,
            wethEthAdapter: address(wethEthAdapter),
            flashLoanAmount: 1 * 1e17,
            ebusdAmount: 500 * 1e18,
            maxUpfrontFee: 2 * 1e18
        });

        FuseAction[] memory leverUpCalls = new FuseAction[](1);
        leverUpCalls[0] = FuseAction(
            address(leverUpFuse),
            abi.encodeWithSignature("execute((address,address,uint256,uint256,uint256))", leverUpData)
        );

        // when
        plasmaVault.execute(leverUpCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        uint256 finalDebt = finalData.entireDebt;
        uint256 finalColl = finalData.entireColl;

        // then
        assertGt(finalDebt, initialDebt, "Debt should have increased after lever up");
        assertGt(finalColl, initialColl, "Collateral should have increased after lever up");

        uint256 debtIncrease = finalDebt - initialDebt;
        assertGe(debtIncrease, (leverUpData.ebusdAmount * 90) / 100);
        assertLe(debtIncrease, (leverUpData.ebusdAmount * 110) / 100);
    }

    function testLeverDownEffectsEbisu() public {
        // given
        testShouldEnterToEbisuZapper();

        uint256 troveId = EbisuMathLibrary.calculateTroveId(address(wethEthAdapter), address(plasmaVault), WEETH_ZAPPER, 1);
        ITroveManager troveManager = ITroveManager(ILeverageZapper(WEETH_ZAPPER).troveManager());

        ITroveManager.LatestTroveData memory initialData = troveManager.getLatestTroveData(troveId);
        uint256 initialDebt = initialData.entireDebt;
        uint256 initialColl = initialData.entireColl;

        EbisuLeverDownData memory leverDownData = EbisuLeverDownData({
            zapper: WEETH_ZAPPER,
            wethEthAdapter: address(wethEthAdapter),
            flashLoanAmount: 5 * 1e16,
            minBoldAmount: 200 * 1e18
        });

        FuseAction[] memory leverDownCalls = new FuseAction[](1);
        leverDownCalls[0] = FuseAction(
            address(leverDownFuse),
            abi.encodeWithSignature("execute((address,address,uint256,uint256))", leverDownData)
        );

        // when
        plasmaVault.execute(leverDownCalls);

        ITroveManager.LatestTroveData memory finalData = troveManager.getLatestTroveData(troveId);
        uint256 finalDebt = finalData.entireDebt;
        uint256 finalColl = finalData.entireColl;

        // then
        assertLt(finalDebt, initialDebt, "Debt should have decreased after lever down");
        assertLt(finalColl, initialColl, "Collateral should have decreased after lever down");

        uint256 debtDecrease = initialDebt - finalDebt;
        assertGe(debtDecrease, (leverDownData.minBoldAmount * 80) / 100);
        assertLe(debtDecrease, (leverDownData.minBoldAmount * 120) / 100);
    }

    // --- helpers ---

    function _setupMarketConfigs() private view returns (MarketSubstratesConfig[] memory marketConfigs_) {
        // EBISU market substrates must include:
        // - all zappers used
        // - the corresponding address registries used
        // - the WETH<->ETH adapter (since the fuse validates it as substrate)
        bytes32[] memory ebisuSubs = new bytes32[](9);
        ebisuSubs[0] = PlasmaVaultConfigLib.addressToBytes32(WEETH_ZAPPER);
        ebisuSubs[1] = PlasmaVaultConfigLib.addressToBytes32(SUSDE_ZAPPER);
        ebisuSubs[2] = PlasmaVaultConfigLib.addressToBytes32(WBTC_ZAPPER);
        ebisuSubs[3] = PlasmaVaultConfigLib.addressToBytes32(LBTC_ZAPPER);
        ebisuSubs[4] = PlasmaVaultConfigLib.addressToBytes32(WEETH_REGISTRY);
        ebisuSubs[5] = PlasmaVaultConfigLib.addressToBytes32(SUSDE_REGISTRY);
        ebisuSubs[6] = PlasmaVaultConfigLib.addressToBytes32(WBTC_REGISTRY);
        ebisuSubs[7] = PlasmaVaultConfigLib.addressToBytes32(LBTC_REGISTRY);
        ebisuSubs[8] = PlasmaVaultConfigLib.addressToBytes32(address(wethEthAdapter)); // adapter

        bytes32[] memory erc20Assets = new bytes32[](2);
        erc20Assets[0] = PlasmaVaultConfigLib.addressToBytes32(EBUSD);
        erc20Assets[1] = PlasmaVaultConfigLib.addressToBytes32(WEETH);

        marketConfigs_ = new MarketSubstratesConfig[](2);
        marketConfigs_[0] = MarketSubstratesConfig(IporFusionMarkets.EBISU, ebisuSubs);
        marketConfigs_[1] = MarketSubstratesConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, erc20Assets);
    }

    function _setupFuses() private returns (address[] memory fuses) {
        zapperFuse   = new EbisuZapperFuse(IporFusionMarkets.EBISU);      // OPEN + CLOSE
        leverUpFuse  = new EbisuZapperLeverUpFuse(IporFusionMarkets.EBISU);
        leverDownFuse= new EbisuZapperLeverDownFuse(IporFusionMarkets.EBISU);

        fuses = new address[](3);
        fuses[0] = address(zapperFuse);
        fuses[1] = address(leverUpFuse);
        fuses[2] = address(leverDownFuse);
    }

    function _setupBalanceFuses() private returns (MarketBalanceFuseConfig[] memory balanceFuses_) {
        balanceFuse = new EbisuZapperBalanceFuse(IporFusionMarkets.EBISU);
        erc20BalanceFuse = new ERC20BalanceFuse(IporFusionMarkets.ERC20_VAULT_BALANCE);
        balanceFuses_ = new MarketBalanceFuseConfig[](2);
        balanceFuses_[0] = MarketBalanceFuseConfig(IporFusionMarkets.EBISU, address(balanceFuse));
        balanceFuses_[1] = MarketBalanceFuseConfig(IporFusionMarkets.ERC20_VAULT_BALANCE, address(erc20BalanceFuse));
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
        RoleLib.setupPlasmaVaultRoles(
            usersToRoles,
            vm,
            address(plasmaVault),
            IporFusionAccessManager(accessManager),
            address(0)
        );
    }
}
