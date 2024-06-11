// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "./../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporPriceOracleMock} from "../priceOracle/IporPriceOracleMock.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {PlasmaVaultAccessManager} from "../../contracts/managers/PlasmaVaultAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";

contract PlasmaVaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    address public atomist = address(this);
    address public alpha = address(0x1);

    string public assetName = "IPOR Fusion DAI";
    string public assetSymbol = "ipfDAI";

    address[] private alphas;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        alphas = new address[](1);
        alphas[0] = alpha;
        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldConfigurePerformanceFeeData() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x777);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        // when
        vm.prank(address(0x777));
        plasmaVault.configurePerformanceFee(address(0x555), 55);

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = plasmaVault.getPerformanceFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldConfigureManagementFeeData() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        // when
        vm.prank(address(0x555));
        plasmaVault.configureManagementFee(address(0x555), 55);

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = plasmaVault.getManagementFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldConfigureManagementFeeDataWhenTimelock() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configureManagementFee(address,uint256)", address(0x555), 55);

        vm.prank(address(0x555));
        accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);

        // when
        vm.prank(address(0x555));
        accessManager.execute(target, data);

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = plasmaVault.getManagementFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldRevertWhenConfigureManagementFeeDontPassTimelock() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configureManagementFee(address,uint256)", address(0x555), 55);

        vm.prank(address(0x555));
        (bytes32 operationId, ) = accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 hours);

        bytes memory error = abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x555));
        plasmaVault.configureManagementFee(address(0x555), 55);
    }

    function testShouldRevertWhenConfigureManagementFeeCallWithoutShouldExecute() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configureManagementFee(address,uint256)", address(0x555), 55);

        vm.prank(address(0x555));
        (bytes32 operationId, ) = accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 hours);

        bytes memory error = abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x555));
        accessManager.execute(target, data);
    }

    function testShouldConfigurePerformanceFeeDataWhenTimelock() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x555);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configurePerformanceFee(address,uint256)", address(0x555), 55);

        vm.prank(address(0x555));
        accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);

        // when
        vm.prank(address(0x555));
        accessManager.execute(target, data);

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = plasmaVault.getPerformanceFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldRevertWhenConfigurePerformanceFeeDontPassTimelock() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x777);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configurePerformanceFee(address,uint256)", address(0x777), 55);

        vm.prank(address(0x777));
        (bytes32 operationId, ) = accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 hours);

        bytes memory error = abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.configurePerformanceFee(address(0x777), 55);
    }

    function testShouldRevertWhenConfigurePerformanceFeeCallWithoutShouldExecute() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x777);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(iporPriceOracleProxy),
                new address[](0),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("configurePerformanceFee(address,uint256)", address(0x777), 55);

        vm.prank(address(0x777));
        (bytes32 operationId, ) = accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 hours);

        bytes memory error = abi.encodeWithSignature("AccessManagerNotReady(bytes32)", operationId);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        accessManager.execute(target, data);
    }

    function testShouldSetupBalanceFusesWhenVaultCreated() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        // then
        assertTrue(
            plasmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should be supported"
        );
    }

    function testShouldAddBalanceFuseByAtomist() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        //when
        plasmaVault.addBalanceFuse(AAVE_V3_MARKET_ID, address(balanceFuse));

        //then
        assertTrue(
            plasmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should be supported"
        );
    }

    function testShouldSetupFusesWhenVaultCreated() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        // then
        assertTrue(plasmaVault.isFuseSupported(address(fuse)), "Fuse should be supported");
    }

    function testShouldAddFusesByAtomist() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        //when
        plasmaVault.addFuses(newSupplyFuses);

        //then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuseAaveV3)), "Fuse AaveV3 should be supported");
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)), "Fuse CompoundV3 should be supported");
    }

    function testShouldAddFusesByOwnerAndExecuteAction() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](2);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        marketConfigs[1] = MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);

        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        FuseAction[] memory calls = new FuseAction[](2);

        uint256 amount = 100 * 1e6;

        deal(USDC, address(this), 2 * amount);

        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        plasmaVault.deposit(2 * amount, address(this));

        calls[0] = FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        calls[1] = FuseAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyFuseEnterData({asset: USDC, amount: amount}))
            )
        );

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        // when
        plasmaVault.addFuses(newSupplyFuses);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarketAaveV3 = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        uint256 vaultTotalAssetsInMarketCompoundV3 = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuseAaveV3)), "Aave V3 supply fuse should be supported");
        assertTrue(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );
        assertGt(vaultTotalAssets, 99e6, "Vault total assets should be greater than 99e6");
        assertEq(
            vaultTotalAssetsInMarketAaveV3,
            amount,
            "Vault total assets in market Aave V3 should be equal to amount"
        );
        assertEq(
            vaultTotalAssetsInMarketCompoundV3,
            99999999,
            "Vault total assets in market Compound V3 should be equal to amount"
        );
    }

    function testShouldNotAddFusesWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.addFuses(newSupplyFuses);

        // then
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseAaveV3)),
            "Fuse AaveV3 should not be supported when not owner"
        );
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Fuse CompoundV3 should not be supported when not owner"
        );
    }

    function testShouldExecutionFailWhenFuseNotAdded() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        FuseAction[] memory calls = new FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(this), 2 * amount);

        ERC20(DAI).approve(address(plasmaVault), 2 * amount);

        plasmaVault.deposit(amount, address(this));

        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        bytes memory error = abi.encodeWithSignature("UnsupportedFuse()");

        // when
        vm.expectRevert(error);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)), "Fuse should not execute when not added");
        assertEq(vaultTotalAssets, amount, "Vault total assets should be equal to amount");
        assertEq(vaultTotalAssetsInMarket, 0, "Vault total assets in market should be equal to 0");
    }

    function testShouldExecutionFailWhenFuseIsRemoved() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        FuseAction[] memory calls = new FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(this), amount);

        ERC20(DAI).approve(address(plasmaVault), amount);

        plasmaVault.deposit(amount, address(this));

        calls[0] = FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        bytes memory error = abi.encodeWithSignature("UnsupportedFuse()");

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuse);
        // when
        plasmaVault.addFuses(fuses);
        plasmaVault.removeFuses(fuses);
        vm.expectRevert(error);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)), "Fuse should not execute when removed");
        assertEq(vaultTotalAssets, amount, "Vault total assets should be equal to amount");
        assertEq(vaultTotalAssetsInMarket, 0, "Vault total assets in market should be equal to 0");
    }

    function testShouldRemoveFuseByAtomist() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        //when
        plasmaVault.removeFuses(fuses);

        //then
        assertFalse(plasmaVault.isFuseSupported(address(fuse)), "Fuse should not be supported");
    }

    function testShouldRemoveFusesByOwner() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](2);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);
        initialSupplyFuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        //when
        plasmaVault.removeFuses(newSupplyFuses);

        //then
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseAaveV3)),
            "Aave V3 supply fuse should not be supported"
        );
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should not be supported"
        );
    }

    function testShouldNotRemoveFusesWhenNotAtomist() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory supplyFuses = new address[](2);
        supplyFuses[0] = address(supplyFuseAaveV3);
        supplyFuses[1] = address(supplyFuseCompoundV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                supplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.removeFuses(supplyFuses);

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuseAaveV3)), "Aave V3 supply fuse should be supported");
        assertTrue(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );
    }

    function testShouldAddAndRemoveFuseWhenAtomist() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseCompoundV3);
        //when
        plasmaVault.addFuses(fuses);

        //then
        assertTrue(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );

        address[] memory fuses2 = new address[](1);
        fuses2[0] = address(supplyFuseAaveV3);

        //when
        plasmaVault.removeFuses(fuses2);

        //then
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseAaveV3)),
            "Aave V3 supply fuse should not be supported"
        );
    }

    function testShouldAddAndRemoveFusesWhenOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](1);
        newSupplyFuses[0] = address(supplyFuseCompoundV3);

        //when
        plasmaVault.addFuses(newSupplyFuses);

        //then
        assertTrue(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );

        //when
        plasmaVault.removeFuses(newSupplyFuses);

        //then
        assertFalse(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should not be supported"
        );
    }

    function testShouldBeAbleToUpdatePriceOracle() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new IporPriceOracleMock(USD, 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        // when
        plasmaVault.setPriceOracle(newPriceOracle);

        // then
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(
            priceOracleBefore,
            address(iporPriceOracleProxy),
            "Price oracle before should be equal to iporPriceOracleProxy"
        );
        assertEq(priceOracleAfter, newPriceOracle, "Price oracle after should be equal to newPriceOracle");
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenDecimalIdWrong() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new IporPriceOracleMock(USD, 6, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracle(string)", Errors.PRICE_ORACLE_ERROR);

        // when
        vm.expectRevert(error);
        plasmaVault.setPriceOracle(newPriceOracle);

        // when
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(
            priceOracleBefore,
            address(iporPriceOracleProxy),
            "Price oracle before should be equal to iporPriceOracleProxy"
        );
        assertEq(
            priceOracleAfter,
            address(iporPriceOracleProxy),
            "Price oracle after should be equal to iporPriceOracleProxy"
        );
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenCurrencyIsWrong() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new IporPriceOracleMock(address(0x777), 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracle(string)", Errors.PRICE_ORACLE_ERROR);

        // when
        vm.expectRevert(error);
        plasmaVault.setPriceOracle(newPriceOracle);

        // when
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(
            priceOracleBefore,
            address(iporPriceOracleProxy),
            "Price oracle before should be equal to iporPriceOracleProxy"
        );
        assertEq(
            priceOracleAfter,
            address(iporPriceOracleProxy),
            "Price oracle after should be equal to iporPriceOracleProxy"
        );
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenNotOwner() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        PlasmaVaultAccessManager accessManager = createAccessManager(usersToRoles);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(iporPriceOracleProxy),
                alphas,
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager)
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new IporPriceOracleMock(USD, 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.setPriceOracle(newPriceOracle);

        // then
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(
            priceOracleBefore,
            address(iporPriceOracleProxy),
            "Price oracle before should be equal to iporPriceOracleProxy"
        );
        assertEq(
            priceOracleAfter,
            address(iporPriceOracleProxy),
            "Price oracle after should be equal to iporPriceOracleProxy"
        );
    }

    function createAccessManager(UsersToRoles memory usersToRoles) public returns (PlasmaVaultAccessManager) {
        if (usersToRoles.superAdmin == address(0)) {
            usersToRoles.superAdmin = atomist;
            usersToRoles.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, PlasmaVaultAccessManager accessManager) public {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }
}
