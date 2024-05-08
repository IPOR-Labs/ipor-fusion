// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
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

    address public owner = address(this);
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
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            "IPOR Fusion DAI",
            "ipfDAI",
            DAI,
            address(iporPriceOracleProxy),
            new address[](0),
            new PlasmaVault.MarketSubstratesConfig[](0),
            new address[](0),
            new PlasmaVault.MarketBalanceFuseConfig[](0),
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

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
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            "IPOR Fusion DAI",
            "ipfDAI",
            DAI,
            address(iporPriceOracleProxy),
            new address[](0),
            new PlasmaVault.MarketSubstratesConfig[](0),
            new address[](0),
            new PlasmaVault.MarketBalanceFuseConfig[](0),
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // when
        vm.prank(address(0x555));
        plasmaVault.configureManagementFee(address(0x555), 55);

        // then
        PlasmaVaultStorageLib.ManagementFeeData memory feeData = plasmaVault.getManagementFeeData();
        assertEq(feeData.feeManager, address(0x555));
        assertEq(feeData.feeInPercentage, 55);
    }

    function testShouldSetupBalanceFusesWhenVaultCreated() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // then
        assertTrue(
            plasmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should be supported"
        );
    }

    function testShouldAddBalanceFuseByOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // then
        assertTrue(plasmaVault.isFuseSupported(address(fuse)), "Fuse should be supported");
    }

    function testShouldAddFuseByOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        //when
        plasmaVault.addFuse(address(fuse));

        //then
        assertTrue(plasmaVault.isFuseSupported(address(fuse)), "Fuse should be supported");
    }

    function testShouldAddFuseByOwnerAndExecuteAction() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory supplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            supplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(this), amount);

        ERC20(DAI).approve(address(plasmaVault), amount);

        plasmaVault.deposit(amount, address(this));

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        // when
        plasmaVault.addFuse(address(supplyFuse));
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        uint256 vaultTotalAssets = plasmaVault.totalAssets();
        uint256 vaultTotalAssetsInMarket = plasmaVault.totalAssetsInMarket(AAVE_V3_MARKET_ID);

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse)), "Fuse should be supported");
        assertEq(vaultTotalAssets, amount, "Vault total assets should be equal to amount");
        assertEq(vaultTotalAssetsInMarket, amount, "Vault total assets in market should be equal to amount");
        assertEq(
            vaultTotalAssets,
            vaultTotalAssetsInMarket,
            "Vault total assets should be equal to vault total assets in market"
        );
    }

    function testShouldAddFusesByOwner() public {
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](2);
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);
        marketConfigs[1] = PlasmaVault.MarketSubstratesConfig(COMPOUND_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);

        AaveV3BalanceFuse balanceFuseAaveV3 = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        CompoundV3BalanceFuse balanceFuseCompoundV3 = new CompoundV3BalanceFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](2);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = PlasmaVault.MarketBalanceFuseConfig(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        AaveV3SupplyFuse supplyFuseAaveV3 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        CompoundV3SupplyFuse supplyFuseCompoundV3 = new CompoundV3SupplyFuse(COMPOUND_V3_MARKET_ID, COMET_V3_USDC);

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        uint256 amount = 100 * 1e6;

        deal(USDC, address(this), 2 * amount);

        ERC20(USDC).approve(address(plasmaVault), 2 * amount);

        plasmaVault.deposit(2 * amount, address(this));

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: USDC, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
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

    function testShouldNotAddFuseWhenNotOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.addFuse(address(supplyFuse));

        // then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)), "Fuse should not be supported when not owner");
    }

    function testShouldNotAddFusesWhenNotOwner() public {
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(this), 2 * amount);

        ERC20(DAI).approve(address(plasmaVault), 2 * amount);

        plasmaVault.deposit(amount, address(this));

        calls[0] = PlasmaVault.FuseAction(
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);
        marketConfigs[0] = PlasmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory initialSupplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlasmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(this), amount);

        ERC20(DAI).approve(address(plasmaVault), amount);

        plasmaVault.deposit(amount, address(this));

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        bytes memory error = abi.encodeWithSignature("UnsupportedFuse()");

        // when
        plasmaVault.addFuse(address(supplyFuse));
        plasmaVault.removeFuse(address(supplyFuse));
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

    function testShouldRemoveFuseByOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        //when
        plasmaVault.removeFuse(address(fuse));

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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](2);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);
        initialSupplyFuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

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

    function testShouldNotRemoveFuseWhenNotOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuse);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.removeFuse(address(supplyFuse));

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse)), "Fuse should be supported");
    }

    function testShouldNotRemoveFusesWhenNotOwner() public {
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory supplyFuses = new address[](2);
        supplyFuses[0] = address(supplyFuseAaveV3);
        supplyFuses[1] = address(supplyFuseCompoundV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            supplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

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

    function testShouldAddAndRemoveFuseWhenOwner() public {
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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

        //when
        plasmaVault.addFuse(address(supplyFuseCompoundV3));

        //then
        assertTrue(
            plasmaVault.isFuseSupported(address(supplyFuseCompoundV3)),
            "Compound V3 supply fuse should be supported"
        );

        //when
        plasmaVault.removeFuse(address(supplyFuseAaveV3));

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

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuseAaveV3);

        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            initialSupplyFuses,
            balanceFuses,
            address(0x777),
            0
        );

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

    function testShouldSetupAlphaWhenVaultCreated() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // then
        assertTrue(plasmaVault.isAlphaGranted(alpha), "Alpha should be granted");
    }

    function testShouldNotSetupAlphaWhenVaultIsCreated() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // then
        assertFalse(plasmaVault.isAlphaGranted(address(0x2)), "Alpha should not be granted");
    }

    function testShouldSetupAlphaByOwner() public {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        //when
        plasmaVault.grantAlpha(address(0x2));

        //then
        assertTrue(plasmaVault.isAlphaGranted(address(0x2)), "Alpha should be granted");
    }

    function testShouldAccessControlDeactivatedAfterCreateVault() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        // when
        bool isAccessControlActive = plasmaVault.isAccessControlActivated();

        // then

        assertFalse(isAccessControlActive, "Access control should be deactivated after vault creation");
    }

    function testShouldBeAbleToActivateAccessControl() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plasmaVault.activateAccessControl();

        // then
        assertTrue(plasmaVault.isAccessControlActivated(), "Access control should be activated");
        assertFalse(isAccessControlActiveBefore, "Access control should not be active before");
    }

    function testShouldNotBeAbleToActivateAccessControlWhenNotOwner() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.activateAccessControl();

        // then
        assertFalse(plasmaVault.isAccessControlActivated(), "Access control should not be activated");
        assertFalse(isAccessControlActiveBefore, "Access control should not be active before");
    }

    function testShouldBeAbleToDeactivateAccessControl() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );
        vm.prank(owner);
        plasmaVault.activateAccessControl();

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plasmaVault.deactivateAccessControl();

        // then
        assertFalse(plasmaVault.isAccessControlActivated(), "Access control should be deactivated");
        assertTrue(isAccessControlActiveBefore, "Access control should be active before");
    }

    function testShouldNotBeAbleToDeactivateAccessControlWhenNotOwner() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );
        vm.prank(owner);
        plasmaVault.activateAccessControl();

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.deactivateAccessControl();

        // then
        assertTrue(plasmaVault.isAccessControlActivated(), "Access control should be activated");
        assertTrue(isAccessControlActiveBefore, "Access control should be active before");
    }

    function testShouldBeAbleToUpdatePriceOracle() external {
        // given
        address underlyingToken = DAI;

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

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
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

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
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

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
        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlasmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlasmaVault.MarketBalanceFuseConfig[](0);

        PlasmaVault plasmaVault = new PlasmaVault(
            owner,
            assetName,
            assetSymbol,
            underlyingToken,
            address(iporPriceOracleProxy),
            alphas,
            marketConfigs,
            fuses,
            balanceFuses,
            PlasmaVault.FeeConfig(address(0x777), 0, address(0x555), 0)
        );

        address newPriceOracle = address(new IporPriceOracleMock(USD, 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

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
}
