// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {VaultFactory} from "../../contracts/vaults/VaultFactory.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {AaveV3SupplyConnector} from "../../contracts/connectors/aave_v3/AaveV3SupplyConnector.sol";
import {AaveV3Balance} from "../../contracts/connectors/aave_v3/AaveV3Balance.sol";
import {CompoundV3Balance} from "../../contracts/connectors/compound_v3/CompoundV3Balance.sol";
import {CompoundV3SupplyConnector} from "../../contracts/connectors/compound_v3/CompoundV3SupplyConnector.sol";
import {MarketConfigurationLib} from "../../contracts/libraries/MarketConfigurationLib.sol";
import {IAavePoolDataProvider} from "../../contracts/connectors/aave_v3/IAavePoolDataProvider.sol";

contract ForkVaultTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    VaultFactory internal vaultFactory;

    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public constant COMET_V3_USDC = 0xc3d688B66703497DAA19211EEdff47f25384cdc3;
    uint256 public constant COMPOUND_V3_MARKET_ID = 2;

    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    address public owner = address(this);

    string public assetName;
    string public assetSymbol;
    address public underlyingToken;
    address[] public keepers;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new VaultFactory(owner);
    }

    function testShouldExecuteSimpleCase() public {
        //given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3Balance balanceConnector = new AaveV3Balance(AAVE_V3_MARKET_ID);

        AaveV3SupplyConnector supplyConnector = new AaveV3SupplyConnector(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory connectors = new address[](1);
        connectors[0] = address(supplyConnector);

        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](1);
        balanceConnectors[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceConnector));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    connectors,
                    balanceConnectors
                )
            )
        );

        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(vault), amount);

        calls[0] = Vault.ConnectorAction(
            address(supplyConnector),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                        token: DAI,
                        amount: amount,
                        userEModeCategoryId: 1e18
                    })
                )
            )
        );

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        assertTrue(true);
    }

    function testShouldExecuteTwoSupplyConnectors() public {
        //given
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3Balance balanceFuseAaveV3 = new AaveV3Balance(AAVE_V3_MARKET_ID);
        AaveV3SupplyConnector supplyFuseAaveV3 = new AaveV3SupplyConnector(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = Vault.MarketConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3Balance balanceFuseCompoundV3 = new CompoundV3Balance(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyConnector supplyFuseCompoundV3 = new CompoundV3SupplyConnector(
            COMET_V3_USDC,
            COMPOUND_V3_MARKET_ID
        );

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](2);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = Vault.FuseStruct(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(vault), 2 * amount);

        calls[0] = Vault.ConnectorAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                        token: USDC,
                        amount: amount,
                        userEModeCategoryId: 1e6
                    })
                )
            )
        );

        calls[1] = Vault.ConnectorAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyConnector.CompoundV3SupplyConnectorData({token: USDC, amount: amount}))
            )
        );

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        assertTrue(true);
    }

    function testShouldUpdateBalanceWhenOneConnector() public {
        //given
        assetName = "IPOR Fusion DAI";
        assetSymbol = "ipfDAI";
        underlyingToken = DAI;
        keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](1);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(DAI);
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);

        AaveV3Balance balanceConnector = new AaveV3Balance(AAVE_V3_MARKET_ID);

        AaveV3SupplyConnector supplyConnector = new AaveV3SupplyConnector(AAVE_POOL, AAVE_V3_MARKET_ID);

        address[] memory connectors = new address[](1);
        connectors[0] = address(supplyConnector);

        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](1);
        balanceConnectors[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceConnector));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    connectors,
                    balanceConnectors
                )
            )
        );

        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(vault), amount);

        calls[0] = Vault.ConnectorAction(
            address(supplyConnector),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                        token: DAI,
                        amount: amount,
                        userEModeCategoryId: 1e18
                    })
                )
            )
        );

        (address aTokenAddress, , ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(DAI);

        uint256 vaultTotalAssetsBefore = vault.totalAssets();

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = vault.totalAssets();

        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vault)) >= amount,
            "aToken balance should be increased by amount"
        );

        assertGt(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should be increased by amount");
    }

    function testShouldUpdateBalanceWhenExecuteTwoSupplyConnectors() public {
        //given
        string memory assetName = "IPOR Fusion USDC";
        string memory assetSymbol = "ipfUSDC";
        address underlyingToken = USDC;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](2);

        bytes32[] memory assets = new bytes32[](1);
        assets[0] = MarketConfigurationLib.addressToBytes32(USDC);

        /// @dev Market Aave V3
        marketConfigs[0] = Vault.MarketConfig(AAVE_V3_MARKET_ID, assets);
        AaveV3Balance balanceFuseAaveV3 = new AaveV3Balance(AAVE_V3_MARKET_ID);
        AaveV3SupplyConnector supplyFuseAaveV3 = new AaveV3SupplyConnector(AAVE_POOL, AAVE_V3_MARKET_ID);

        /// @dev Market Compound V3
        marketConfigs[1] = Vault.MarketConfig(COMPOUND_V3_MARKET_ID, assets);
        CompoundV3Balance balanceFuseCompoundV3 = new CompoundV3Balance(COMET_V3_USDC, COMPOUND_V3_MARKET_ID);
        CompoundV3SupplyConnector supplyFuseCompoundV3 = new CompoundV3SupplyConnector(
            COMET_V3_USDC,
            COMPOUND_V3_MARKET_ID
        );

        address[] memory fuses = new address[](2);
        fuses[0] = address(supplyFuseAaveV3);
        fuses[1] = address(supplyFuseCompoundV3);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](2);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuseAaveV3));
        balanceFuses[1] = Vault.FuseStruct(COMPOUND_V3_MARKET_ID, address(balanceFuseCompoundV3));

        Vault vault = Vault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    keepers,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        Vault.ConnectorAction[] memory calls = new Vault.ConnectorAction[](2);

        uint256 amount = 100 * 1e6;

        vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9);
        ERC20(USDC).transfer(address(vault), 2 * amount);

        calls[0] = Vault.ConnectorAction(
            address(supplyFuseAaveV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(
                    AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                        token: USDC,
                        amount: amount,
                        userEModeCategoryId: 1e6
                    })
                )
            )
        );

        calls[1] = Vault.ConnectorAction(
            address(supplyFuseCompoundV3),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(CompoundV3SupplyConnector.CompoundV3SupplyConnectorData({token: USDC, amount: amount}))
            )
        );

        uint256 vaultTotalAssetsBefore = vault.totalAssets();

        //when
        vm.prank(keeper);
        vault.execute(calls);

        //then
        uint256 vaultTotalAssetsAfter = vault.totalAssets();

        assertGt(vaultTotalAssetsAfter, vaultTotalAssetsBefore, "Vault total assets should be increased by amount");
        assertGt(vaultTotalAssetsAfter, 199e18, "Vault total assets should be increased by amount + amount - 1");
    }
}
