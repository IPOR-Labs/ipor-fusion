// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault, MarketSubstratesConfig, MarketBalanceFuseConfig, FuseAction, FeeConfig, PlasmaVaultInitData} from "../../contracts/vaults/PlasmaVault.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PlasmaVaultConfigLib} from "./../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {CompoundV3BalanceFuse} from "../../contracts/fuses/compound_v3/CompoundV3BalanceFuse.sol";
import {CompoundV3SupplyFuse, CompoundV3SupplyFuseEnterData} from "../../contracts/fuses/compound_v3/CompoundV3SupplyFuse.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareMock} from "../price_oracle/PriceOracleMiddlewareMock.sol";
import {PlasmaVaultStorageLib} from "../../contracts/libraries/PlasmaVaultStorageLib.sol";
import {IporFusionAccessManager} from "../../contracts/managers/access/IporFusionAccessManager.sol";
import {RoleLib, UsersToRoles} from "../RoleLib.sol";
import {MarketLimit} from "../../contracts/libraries/AssetDistributionProtectionLib.sol";
import {Roles} from "../../contracts/libraries/Roles.sol";
import {PlasmaVaultBase} from "../../contracts/vaults/PlasmaVaultBase.sol";
import {IPlasmaVaultGovernance} from "../../contracts/interfaces/IPlasmaVaultGovernance.sol";

contract PlasmaVaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
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

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        alphas = new address[](1);
        alphas[0] = alpha;
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        // when
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).configurePerformanceFee(address(0x555), 55);

        // then
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = IPlasmaVaultGovernance(address(plasmaVault))
            .getPerformanceFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldConfigureManagementFeeData() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        // when
        vm.prank(address(0x555));
        IPlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(address(0x555), 55);

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = IPlasmaVaultGovernance(address(plasmaVault))
            .getManagementFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldNotConfigureManagementFeeDataBecauseOfCap() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("InvalidManagementFee(uint256)", 501);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x555));
        IPlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(address(0x555), 501);
    }

    function testShouldNotCinfigurePerformanceFeeDataBecauseOfCap() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x777);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("InvalidPerformanceFee(uint256)", 5001);

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).configurePerformanceFee(address(0x555), 5001);
    }

    function testShouldConfigureManagementFeeDataWhenTimelock() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = IPlasmaVaultGovernance(address(plasmaVault))
            .getManagementFeeData();
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IPlasmaVaultGovernance(address(plasmaVault)).configureManagementFee(address(0x555), 55);
    }

    function testShouldRevertWhenConfigureManagementFeeCallWithoutShouldExecute() public {
        // given

        UsersToRoles memory usersToRoles;
        address[] memory managementFeeManagers = new address[](1);
        managementFeeManagers[0] = address(0x555);
        usersToRoles.managementFeeManagers = managementFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        PlasmaVaultStorageLib.PerformanceFeeData memory feeData = IPlasmaVaultGovernance(address(plasmaVault))
            .getPerformanceFeeData();
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IPlasmaVaultGovernance(address(plasmaVault)).configurePerformanceFee(address(0x777), 55);
    }

    function testShouldRevertWhenConfigurePerformanceFeeCallWithoutShouldExecute() public {
        // given
        UsersToRoles memory usersToRoles;
        address[] memory performanceFeeManagers = new address[](1);
        performanceFeeManagers[0] = address(0x777);
        usersToRoles.performanceFeeManagers = performanceFeeManagers;
        usersToRoles.feeTimelock = 1 days;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                "IPOR Fusion DAI",
                "ipfDAI",
                DAI,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        // then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                AAVE_V3_MARKET_ID,
                address(balanceFuse)
            ),
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
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).addBalanceFuse(AAVE_V3_MARKET_ID, address(balanceFuse));

        //then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isBalanceFuseSupported(
                AAVE_V3_MARKET_ID,
                address(balanceFuse)
            ),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        // then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(fuse)),
            "Fuse should be supported"
        );
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(newSupplyFuses);

        //then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
            "Fuse AaveV3 should be supported"
        );
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
            "Fuse CompoundV3 should be supported"
        );
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
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](2);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(newSupplyFuses);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarketAaveV3 = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);
        uint256 vaultTotalAssetsInMarketCompoundV3 = plasmaVault.totalAssetsInMarket(COMPOUND_V3_MARKET_ID);

        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
            "Aave V3 supply fuse should be supported"
        );
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(newSupplyFuses);

        // then
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
            "Fuse AaveV3 should not be supported when not owner"
        );
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
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
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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

        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuse)),
            "Fuse should not execute when not added"
        );
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
            AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](1);
        balanceFuses[0] = MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
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
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(fuses);
        vm.expectRevert(error);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuse)),
            "Fuse should not execute when removed"
        );
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(fuses);

        //then
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(fuse)),
            "Fuse should not be supported"
        );
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuseAaveV3);
        newSupplyFuses[1] = address(supplyFuseCompoundV3);

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(newSupplyFuses);

        //then
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
            "Aave V3 supply fuse should not be supported"
        );
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                supplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(supplyFuses);

        // then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
            "Aave V3 supply fuse should be supported"
        );
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory fuses = new address[](1);
        fuses[0] = address(supplyFuseCompoundV3);
        //when
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(fuses);

        //then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );

        address[] memory fuses2 = new address[](1);
        fuses2[0] = address(supplyFuseAaveV3);

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(fuses2);

        //then
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseAaveV3)),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address[] memory newSupplyFuses = new address[](1);
        newSupplyFuses[0] = address(supplyFuseCompoundV3);

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).addFuses(newSupplyFuses);

        //then
        assertTrue(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );

        //when
        IPlasmaVaultGovernance(address(plasmaVault)).removeFuses(newSupplyFuses);

        //then
        assertFalse(
            IPlasmaVaultGovernance(address(plasmaVault)).isFuseSupported(address(supplyFuseCompoundV3)),
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracleMiddleware = address(new PriceOracleMiddlewareMock(USD, 8, address(0)));
        address priceOracleBefore = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        // when
        IPlasmaVaultGovernance(address(plasmaVault)).setPriceOracleMiddleware(newPriceOracleMiddleware);

        // then
        address priceOracleAfter = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        assertEq(
            priceOracleBefore,
            address(priceOracleMiddlewareProxy),
            "Price oracle before should be equal to priceOracleMiddlewareProxy"
        );
        assertEq(priceOracleAfter, newPriceOracleMiddleware, "Price oracle after should be equal to newPriceOracle");
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new PriceOracleMiddlewareMock(USD, 6, address(0)));
        address priceOracleBefore = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracleMiddleware()");

        // when
        vm.expectRevert(error);
        IPlasmaVaultGovernance(address(plasmaVault)).setPriceOracleMiddleware(newPriceOracle);

        // when
        address priceOracleAfter = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        assertEq(
            priceOracleBefore,
            address(priceOracleMiddlewareProxy),
            "Price oracle before should be equal to priceOracleMiddlewareProxy"
        );
        assertEq(
            priceOracleAfter,
            address(priceOracleMiddlewareProxy),
            "Price oracle after should be equal to priceOracleMiddlewareProxy"
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new PriceOracleMiddlewareMock(address(0x777), 8, address(0)));
        address priceOracleBefore = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracleMiddleware()");

        // when
        vm.expectRevert(error);
        IPlasmaVaultGovernance(address(plasmaVault)).setPriceOracleMiddleware(newPriceOracle);

        // when
        address priceOracleAfter = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        assertEq(
            priceOracleBefore,
            address(priceOracleMiddlewareProxy),
            "Price oracle before should be equal to priceOracleMiddlewareProxy"
        );
        assertEq(
            priceOracleAfter,
            address(priceOracleMiddlewareProxy),
            "Price oracle after should be equal to priceOracleMiddlewareProxy"
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
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                fuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        address newPriceOracle = address(new PriceOracleMiddlewareMock(USD, 8, address(0)));
        address priceOracleBefore = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).setPriceOracleMiddleware(newPriceOracle);

        // then
        address priceOracleAfter = IPlasmaVaultGovernance(address(plasmaVault)).getPriceOracleMiddleware();

        assertEq(
            priceOracleBefore,
            address(priceOracleMiddlewareProxy),
            "Price oracle before should be equal to priceOracleMiddlewareProxy"
        );
        assertEq(
            priceOracleAfter,
            address(priceOracleMiddlewareProxy),
            "Price oracle after should be equal to priceOracleMiddlewareProxy"
        );
    }

    function createAccessManager(
        UsersToRoles memory usersToRoles_,
        uint256 redemptionDelay_
    ) public returns (IporFusionAccessManager) {
        if (usersToRoles_.superAdmin == address(0)) {
            usersToRoles_.superAdmin = atomist;
            usersToRoles_.atomist = atomist;
            address[] memory alphas = new address[](1);
            alphas[0] = alpha;
            usersToRoles_.alphas = alphas;
        }
        return RoleLib.createAccessManager(usersToRoles_, redemptionDelay_, vm);
    }

    function setupRoles(PlasmaVault plasmaVault, IporFusionAccessManager accessManager) public {
        UsersToRoles memory usersToRoles;
        usersToRoles.superAdmin = atomist;
        usersToRoles.atomist = atomist;
        RoleLib.setupPlasmaVaultRoles(usersToRoles, vm, address(plasmaVault), accessManager);
    }

    function testShouldNotActivateMarketsLimitWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();
    }

    function testShouldActivateMarketsLimitWhenAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bool isMarketsLimitsActivatedBefore = IPlasmaVaultGovernance(address(plasmaVault)).isMarketsLimitsActivated();

        // when
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();

        // then
        bool isMarketsLimitsActivatedAfter = IPlasmaVaultGovernance(address(plasmaVault)).isMarketsLimitsActivated();

        assertFalse(isMarketsLimitsActivatedBefore, "Markets limits should not be activated before");
        assertTrue(isMarketsLimitsActivatedAfter, "Markets limits should be activated after");
    }

    function testShouldDeactivateMarketsLimitWhenAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();

        bool isMarketsLimitsActivatedBefore = IPlasmaVaultGovernance(address(plasmaVault)).isMarketsLimitsActivated();

        // when
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).deactivateMarketsLimits();

        // then
        bool isMarketsLimitsActivatedAfter = IPlasmaVaultGovernance(address(plasmaVault)).isMarketsLimitsActivated();

        assertTrue(isMarketsLimitsActivatedBefore, "Markets limits should be activated before");
        assertFalse(isMarketsLimitsActivatedAfter, "Markets limits should not be activated after");
    }

    function testShouldNotDeactivateMarketsLimitWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).deactivateMarketsLimits();
    }

    function testShouldNotBeAbleToSetupLimitForMarketWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", address(0x777));

        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).activateMarketsLimits();

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        IPlasmaVaultGovernance(address(plasmaVault)).deactivateMarketsLimits();
    }

    function testShouldBeAbleToSetupLimitForMarketWhenAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint256 limitBefore = IPlasmaVaultGovernance(address(plasmaVault)).getMarketLimit(AAVE_V3_MARKET_ID);

        MarketLimit[] memory marketsLimits = new MarketLimit[](1);
        marketsLimits[0] = MarketLimit(AAVE_V3_MARKET_ID, 1e17);

        // when
        vm.prank(atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).setupMarketsLimits(marketsLimits);

        //then
        uint256 limitAfter = IPlasmaVaultGovernance(address(plasmaVault)).getMarketLimit(AAVE_V3_MARKET_ID);

        assertEq(limitBefore, 0, "Limit before should be equal to 0");
        assertEq(limitAfter, 1e17, "Limit after should be equal to 1e17");
    }

    function testShouldNotBeAbleToCloseMarketWhenUserHasNoGuardianRole() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", alpha);

        // when
        vm.expectRevert(error);
        vm.prank(alpha);
        accessManager.updateTargetClosed(address(plasmaVault), true);
    }

    function testShouldBeAbleToCloseMarket() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bool isClosedBefore = accessManager.isTargetClosed(address(plasmaVault));

        // when
        vm.prank(atomist);
        accessManager.updateTargetClosed(address(plasmaVault), true);

        // then
        bool isClosedAfter = accessManager.isTargetClosed(address(plasmaVault));

        assertFalse(isClosedBefore, "Market should not be closed before");
        assertTrue(isClosedAfter, "Market should be closed after");
    }

    function testShouldBeAbleToOpenMarket() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);
        vm.prank(atomist);
        accessManager.updateTargetClosed(address(plasmaVault), true);

        bool isClosedBefore = accessManager.isTargetClosed(address(plasmaVault));

        // when
        vm.prank(atomist);
        accessManager.updateTargetClosed(address(plasmaVault), false);

        // then
        bool isClosedAfter = accessManager.isTargetClosed(address(plasmaVault));

        assertTrue(isClosedBefore, "Market should be closed before");
        assertFalse(isClosedAfter, "Market should not be closed after");
    }

    function testShouldBeAbleToMakePlasmaVaultPublic() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.deposit.selector;
        sig[1] = PlasmaVault.mint.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        bool canDepositBefore;
        bool canMintBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        try plasmaVault.deposit(10e18, user) {
            canDepositBefore = true;
        } catch {
            canDepositBefore = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintBefore = true;
        } catch {
            canMintBefore = false;
        }
        vm.stopPrank();

        // when
        vm.prank(usersToRoles.atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).convertToPublicVault();

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.deposit(10e18, user) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }
        vm.stopPrank();

        assertFalse(canDepositBefore, "User should not be able to deposit before");
        assertFalse(canMintBefore, "User should not be able to mint before");
        assertTrue(canDepositAfter, "User should be able to deposit after");
        assertTrue(canMintAfter, "User should be able to mint after");
    }

    function testShouldBeAbleToMakePlasmaVaultPublicWithTimelock() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.deposit.selector;
        sig[1] = PlasmaVault.mint.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        address userAtomist = address(0x777);
        vm.prank(usersToRoles.atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, userAtomist, uint32(100));

        bool canDepositBefore;
        bool canMintBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        try plasmaVault.deposit(10e18, user) {
            canDepositBefore = true;
        } catch {
            canDepositBefore = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintBefore = true;
        } catch {
            canMintBefore = false;
        }
        vm.stopPrank();

        // when
        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("convertToPublicVault()");

        vm.prank(userAtomist);
        accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);

        vm.prank(userAtomist);
        accessManager.execute(target, data);

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.deposit(10e18, user) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }
        vm.stopPrank();

        assertFalse(canDepositBefore, "User should not be able to deposit before");
        assertFalse(canMintBefore, "User should not be able to mint before");
        assertTrue(canDepositAfter, "User should be able to deposit after");
        assertTrue(canMintAfter, "User should be able to mint after");
    }

    function testShouldNotBeAbleToMakePlasmaVaultPublicWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.deposit.selector;
        sig[1] = PlasmaVault.mint.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        bool canDepositBefore;
        bool canMintBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        try plasmaVault.deposit(10e18, user) {
            canDepositBefore = true;
        } catch {
            canDepositBefore = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintBefore = true;
        } catch {
            canMintBefore = false;
        }
        vm.stopPrank();

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", user);
        // when
        vm.prank(user);
        vm.expectRevert(error);
        accessManager.convertToPublicVault(address(plasmaVault));

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.deposit(10e18, user) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        try plasmaVault.mint(10e18, user) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }
        vm.stopPrank();

        assertFalse(canDepositBefore, "User should not be able to deposit before");
        assertFalse(canMintBefore, "User should not be able to mint before");
        assertFalse(canDepositAfter, "User should not be able to deposit after");
        assertFalse(canMintAfter, "User should not be able to mint after");
    }

    function testShouldBeAbleToEnableTransferShares() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.transfer.selector;
        sig[1] = PlasmaVault.transferFrom.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        bool canTransferBefore;
        bool canTransferFromBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        ERC20(address(plasmaVault)).approve(address(this), 100e18);
        plasmaVault.deposit(50e18, user);

        try plasmaVault.transfer(address(this), 10e18) {
            canTransferBefore = true;
        } catch {
            canTransferBefore = false;
        }
        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canTransferFromBefore = true;
        } catch {
            canTransferFromBefore = false;
        }

        // when
        vm.prank(usersToRoles.atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).enableTransferShares();

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.transfer(address(this), 10e18) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }

        assertFalse(canTransferBefore, "User should not be able to deposit before");
        assertFalse(canTransferFromBefore, "User should not be able to mint before");
        assertTrue(canDepositAfter, "User should be able to deposit after");
        assertTrue(canMintAfter, "User should be able to mint after");
    }

    function testShouldBeAbleToEnableTransferSharesWithTimelock() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.transfer.selector;
        sig[1] = PlasmaVault.transferFrom.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        address userAtomist = address(0x555);
        vm.prank(usersToRoles.atomist);
        accessManager.grantRole(Roles.ATOMIST_ROLE, userAtomist, uint32(100));

        bool canTransferBefore;
        bool canTransferFromBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        ERC20(address(plasmaVault)).approve(address(this), 100e18);
        plasmaVault.deposit(50e18, user);

        try plasmaVault.transfer(address(this), 10e18) {
            canTransferBefore = true;
        } catch {
            canTransferBefore = false;
        }
        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canTransferFromBefore = true;
        } catch {
            canTransferFromBefore = false;
        }

        // when
        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature("enableTransferShares()");

        vm.prank(userAtomist);
        accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);

        vm.prank(userAtomist);
        accessManager.execute(target, data);

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.transfer(address(this), 10e18) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }

        assertFalse(canTransferBefore, "User should not be able to deposit before");
        assertFalse(canTransferFromBefore, "User should not be able to mint before");
        assertTrue(canDepositAfter, "User should be able to deposit after");
        assertTrue(canMintAfter, "User should be able to mint after");
    }

    function testShouldNotBeAbleToEnableTransferSharesWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        bytes4[] memory sig = new bytes4[](2);
        sig[0] = PlasmaVault.transfer.selector;
        sig[1] = PlasmaVault.transferFrom.selector;

        vm.prank(usersToRoles.superAdmin);
        accessManager.setTargetFunctionRole(address(plasmaVault), sig, Roles.WHITELIST_ROLE);

        address user = address(0x555);

        deal(USDC, user, 100e18);

        bool canTransferBefore;
        bool canTransferFromBefore;

        vm.startPrank(user);
        ERC20(USDC).approve(address(plasmaVault), 100e18);
        ERC20(address(plasmaVault)).approve(address(this), 100e18);
        plasmaVault.deposit(50e18, user);

        try plasmaVault.transfer(address(this), 10e18) {
            canTransferBefore = true;
        } catch {
            canTransferBefore = false;
        }
        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canTransferFromBefore = true;
        } catch {
            canTransferFromBefore = false;
        }

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", user);

        // when
        vm.prank(user);
        vm.expectRevert(error);
        accessManager.enableTransferShares(address(plasmaVault));

        // then
        bool canDepositAfter;
        bool canMintAfter;

        vm.startPrank(user);
        try plasmaVault.transfer(address(this), 10e18) {
            canDepositAfter = true;
        } catch {
            canDepositAfter = false;
        }

        vm.stopPrank();

        try plasmaVault.transferFrom(user, address(this), 10e18) {
            canMintAfter = true;
        } catch {
            canMintAfter = false;
        }

        assertFalse(canTransferBefore, "User should not be able to deposit before");
        assertFalse(canTransferFromBefore, "User should not be able to mint before");
        assertFalse(canDepositAfter, "User should not be able to deposit after");
        assertFalse(canMintAfter, "User should not be able to mint after");
    }

    function testShouldBeAbleToSetupMinimalExecutionTimelockOnRole() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        address owner = usersToRoles.atomist;
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint64[] memory roles = new uint64[](2);
        roles[0] = Roles.ALPHA_ROLE;
        roles[1] = Roles.ATOMIST_ROLE;

        uint256[] memory timeLocks = new uint256[](2);
        timeLocks[0] = 100;
        timeLocks[1] = 200;

        uint256 alphaTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        // when
        vm.prank(owner);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roles, timeLocks);

        // then
        uint256 alphaTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        assertEq(alphaTimeLockBefore, 0, "Alpha time lock before should be equal to 0");
        assertEq(atomistTimeLockBefore, 0, "Atomist time lock before should be equal to 0");
        assertEq(alphaTimeLockAfter, 100, "Alpha time lock after should be equal to 100");
        assertEq(atomistTimeLockAfter, 200, "Atomist time lock after should be equal to 200");
    }

    function testShouldBeAbleToSetupMinimalExecutionTimelockOnRoleWithTimelock() public {
        // given
        address underlyingToken = USDC;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        address owner = usersToRoles.atomist;
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint64[] memory roles = new uint64[](2);
        roles[0] = Roles.ALPHA_ROLE;
        roles[1] = Roles.ATOMIST_ROLE;

        uint256[] memory timeLocks = new uint256[](2);
        timeLocks[0] = 100;
        timeLocks[1] = 200;

        uint256 alphaTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        address userOwner = address(0x555);
        vm.prank(owner);
        accessManager.grantRole(Roles.OWNER_ROLE, userOwner, uint32(100));

        // when
        address target = address(plasmaVault);
        bytes memory data = abi.encodeWithSignature(
            "setMinimalExecutionDelaysForRoles(uint64[],uint256[])",
            roles,
            timeLocks
        );

        vm.prank(userOwner);
        accessManager.schedule(target, data, uint48(block.timestamp + 1 days));

        vm.warp(block.timestamp + 1 days);

        vm.prank(userOwner);
        accessManager.execute(target, data);

        // then
        uint256 alphaTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        assertEq(alphaTimeLockBefore, 0, "Alpha time lock before should be equal to 0");
        assertEq(atomistTimeLockBefore, 0, "Atomist time lock before should be equal to 0");
        assertEq(alphaTimeLockAfter, 100, "Alpha time lock after should be equal to 100");
        assertEq(atomistTimeLockAfter, 200, "Atomist time lock after should be equal to 200");
    }

    function testShouldNotBeAbleToSetupMinimalExecutionTimelockOnRoleWhenNotOwner() public {
        // given
        address underlyingToken = USDC;
        address user = address(0x555);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint64[] memory roles = new uint64[](2);
        roles[0] = Roles.ALPHA_ROLE;
        roles[1] = Roles.ATOMIST_ROLE;

        uint256[] memory timeLocks = new uint256[](2);
        timeLocks[0] = 100;
        timeLocks[1] = 200;

        uint256 alphaTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockBefore = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", user);
        // when
        vm.prank(user);
        vm.expectRevert(error);
        accessManager.setMinimalExecutionDelaysForRoles(roles, timeLocks);

        // then
        uint256 alphaTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ALPHA_ROLE);
        uint256 atomistTimeLockAfter = accessManager.getMinimalExecutionDelayForRole(Roles.ATOMIST_ROLE);

        assertEq(alphaTimeLockBefore, 0, "Alpha time lock before should be equal to 0");
        assertEq(atomistTimeLockBefore, 0, "Atomist time lock before should be equal to 0");
        assertEq(alphaTimeLockAfter, 0, "Alpha time lock after should be equal to 0");
        assertEq(atomistTimeLockAfter, 0, "Atomist time lock after should be equal to 0");
    }

    function testShouldBeAbleToGrantRole() public {
        // given
        address underlyingToken = USDC;
        address user = address(0x555);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint64[] memory roles = new uint64[](2);
        roles[0] = Roles.ALPHA_ROLE;
        roles[1] = Roles.ATOMIST_ROLE;

        uint256[] memory timeLocks = new uint256[](2);
        timeLocks[0] = 100;
        timeLocks[1] = 200;

        vm.prank(usersToRoles.atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roles, timeLocks);

        (bool isMemberBefore, uint32 executionDelayBefore) = accessManager.hasRole(Roles.ALPHA_ROLE, user);

        // when
        vm.prank(usersToRoles.atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, user, uint32(timeLocks[1]));

        // then
        (bool isMemberAfter, uint32 executionDelayAfter) = accessManager.hasRole(Roles.ALPHA_ROLE, user);

        assertFalse(isMemberBefore, "User should not be a member before");
        assertEq(executionDelayBefore, 0, "Execution delay before should be equal to 0");
        assertTrue(isMemberAfter, "User should be a member after");
        assertEq(executionDelayAfter, 200, "Execution delay after should be equal to 200");
    }

    function testShouldNotBeAbleToGrantRoleWhenExecutionDaleyTooSmall() public {
        // given
        address underlyingToken = USDC;
        address user = address(0x555);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint64[] memory roles = new uint64[](2);
        roles[0] = Roles.ALPHA_ROLE;
        roles[1] = Roles.ATOMIST_ROLE;

        uint256[] memory timeLocks = new uint256[](2);
        timeLocks[0] = 100;
        timeLocks[1] = 200;

        vm.prank(usersToRoles.atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).setMinimalExecutionDelaysForRoles(roles, timeLocks);

        (bool isMemberBefore, ) = accessManager.hasRole(Roles.ALPHA_ROLE, user);

        bytes memory error = abi.encodeWithSignature(
            "TooShortExecutionDelayForRole(uint64,uint32)",
            Roles.ALPHA_ROLE,
            uint32(99)
        );

        // when
        vm.expectRevert(error);
        vm.prank(usersToRoles.atomist);
        accessManager.grantRole(Roles.ALPHA_ROLE, user, uint32(99));

        // then
        (bool isMemberAfter, ) = accessManager.hasRole(Roles.ALPHA_ROLE, user);

        assertFalse(isMemberBefore, "User should not be a member before");
        assertFalse(isMemberAfter, "User should not be a member after");
    }

    function testShouldBeAbleToSetupDependencyBalanceGraph() public {
        // given
        address underlyingToken = USDC;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint256[] memory marketIdsBefore = IPlasmaVaultGovernance(address(plasmaVault)).getDependencyBalanceGraph(1);

        uint256[] memory marketIdsToUpdate = new uint256[](2);
        marketIdsToUpdate[0] = 1;
        marketIdsToUpdate[1] = 2;

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = 1;
        uint256[][] memory marketDependency = new uint256[][](1);

        marketDependency[0] = marketIdsToUpdate;

        // when
        vm.prank(usersToRoles.atomist);
        IPlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, marketDependency);

        // then
        uint256[] memory marketIdsAfter = IPlasmaVaultGovernance(address(plasmaVault)).getDependencyBalanceGraph(1);

        assertEq(marketIdsBefore.length, 0, "Market ids before should be empty");
        assertEq(marketIdsAfter.length, 2, "Market ids after should have length 2");
        assertEq(marketIdsAfter[0], 1, "Market id 1 should be first");
        assertEq(marketIdsAfter[1], 2, "Market id 2 should be second");
    }

    function testShouldNotBeAbleToSetupTotalSupplyCapEqualZero() public {
        // given
        address underlyingToken = USDC;

        UsersToRoles memory usersToRoles;

        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);

        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                new MarketSubstratesConfig[](0),
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        bytes memory error = abi.encodeWithSignature("WrongValue()");

        //when
        vm.prank(usersToRoles.atomist);
        vm.expectRevert(error);
        IPlasmaVaultGovernance(address(plasmaVault)).setTotalSupplyCap(0);
    }

    function testShouldNotBeAbleToSetupDependencyBalanceGraphWhenNotAtomist() public {
        // given
        address underlyingToken = USDC;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        uint256[] memory marketIdsBefore = IPlasmaVaultGovernance(address(plasmaVault)).getDependencyBalanceGraph(1);

        uint256[] memory marketIdsToUpdate = new uint256[](2);
        marketIdsToUpdate[0] = 1;
        marketIdsToUpdate[1] = 2;

        uint256[] memory marketIds = new uint256[](1);
        marketIds[0] = 1;
        uint256[][] memory marketDependency = new uint256[][](1);

        marketDependency[0] = marketIdsToUpdate;

        bytes memory error = abi.encodeWithSignature("AccessManagedUnauthorized(address)", usersToRoles.alphas[0]);

        // when
        vm.prank(usersToRoles.alphas[0]);
        vm.expectRevert(error);
        IPlasmaVaultGovernance(address(plasmaVault)).updateDependencyBalanceGraphs(marketIds, marketDependency);

        // then
        uint256[] memory marketIdsAfter = IPlasmaVaultGovernance(address(plasmaVault)).getDependencyBalanceGraph(1);

        assertEq(marketIdsBefore.length, 0, "Market ids before should be empty");
        assertEq(marketIdsAfter.length, 0, "Market ids after should be empty");
    }

    function testShouldDisplayMarketSubstrates() public {
        // given
        address underlyingToken = USDC;

        address usdt = address(0x777);
        address dai = address(0x888);

        bytes32[] memory substrates = new bytes32[](3);
        substrates[0] = PlasmaVaultConfigLib.addressToBytes32(USDC);
        substrates[1] = PlasmaVaultConfigLib.addressToBytes32(usdt);
        substrates[2] = PlasmaVaultConfigLib.addressToBytes32(dai);

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](1);
        marketConfigs[0] = MarketSubstratesConfig(1, substrates);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                new address[](0),
                new MarketBalanceFuseConfig[](0),
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        // when
        bytes32[] memory substratesResult = IPlasmaVaultGovernance(address(plasmaVault)).getMarketSubstrates(1);

        // then
        assertEq(substratesResult.length, 3, "Substrates should have length 3");
        assertEq(
            uint256(substratesResult[0]),
            uint256(PlasmaVaultConfigLib.addressToBytes32(USDC)),
            "First substrate should be USDC"
        );
        assertEq(
            uint256(substratesResult[1]),
            uint256(PlasmaVaultConfigLib.addressToBytes32(usdt)),
            "Second substrate should be USDT"
        );
        assertEq(
            uint256(substratesResult[2]),
            uint256(PlasmaVaultConfigLib.addressToBytes32(dai)),
            "Third substrate should be DAI"
        );
    }

    function testShouldNotSetMarketLimits() public {
        // given
        address underlyingToken = USDC;

        MarketSubstratesConfig[] memory marketConfigs = new MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        MarketBalanceFuseConfig[] memory balanceFuses = new MarketBalanceFuseConfig[](0);

        UsersToRoles memory usersToRoles;
        IporFusionAccessManager accessManager = createAccessManager(usersToRoles, 0);
        PlasmaVault plasmaVault = new PlasmaVault(
            PlasmaVaultInitData(
                assetName,
                assetSymbol,
                underlyingToken,
                address(priceOracleMiddlewareProxy),
                marketConfigs,
                initialSupplyFuses,
                balanceFuses,
                FeeConfig(address(0x777), 0, address(0x555), 0),
                address(accessManager),
                address(new PlasmaVaultBase()),
                type(uint256).max
            )
        );

        setupRoles(plasmaVault, accessManager);

        MarketLimit[] memory marketsLimits = new MarketLimit[](1);
        marketsLimits[0] = MarketLimit(1, 1e18 + 1);

        // when
        bytes memory error = abi.encodeWithSignature("MarketLimitSetupInPercentageIsTooHigh(uint256)", 1e18 + 1);

        //when
        vm.prank(usersToRoles.atomist);
        //then
        vm.expectRevert(error);
        IPlasmaVaultGovernance(address(plasmaVault)).setupMarketsLimits(marketsLimits);
    }
}
