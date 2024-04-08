// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../contracts/vaults/VaultFactory.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {AaveV3SupplyConnector} from "../../contracts/connectors/aave_v3/AaveV3SupplyConnector.sol";
import {AaveV3Balance} from "../../contracts/connectors/aave_v3/AaveV3Balance.sol";

contract VaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    VaultFactory internal vaultFactory;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public owner = address(this);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new VaultFactory(owner);
    }

    function testShouldSetupBalanceConnectorsWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        AaveV3Balance balanceConnector = new AaveV3Balance(AAVE_V3_MARKET_ID);

        address[] memory connectors = new address[](0);

        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](1);
        balanceConnectors[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceConnector));

        // when
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

        // then
        assertTrue(vault.isBalanceConnectorSupported(AAVE_V3_MARKET_ID, address(balanceConnector)));
    }

    function testShouldAddBalanceConnectorByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        AaveV3Balance balanceConnector = new AaveV3Balance(AAVE_V3_MARKET_ID);

        address[] memory connectors = new address[](0);
        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

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

        assertFalse(
            vault.isBalanceConnectorSupported(AAVE_V3_MARKET_ID, address(balanceConnector)),
            "Balance connector should not be supported"
        );

        //when
        vault.addBalanceFuse(Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceConnector)));

        //then
        assertTrue(
            vault.isBalanceConnectorSupported(AAVE_V3_MARKET_ID, address(balanceConnector)),
            "Balance connector should be supported"
        );
    }

    function testShouldSetupConnectorsWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](1);
        AaveV3SupplyConnector connector = new AaveV3SupplyConnector(address(0x1), AAVE_V3_MARKET_ID);
        connectors[0] = address(connector);

        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

        // when
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

        // then
        assertTrue(vault.isConnectorSupported(address(connector)));
    }

    function testShouldAddConnectorByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](0);
        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

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

        AaveV3SupplyConnector connector = new AaveV3SupplyConnector(address(0x1), AAVE_V3_MARKET_ID);

        assertFalse(vault.isConnectorSupported(address(connector)));

        //when
        vault.addConnector(address(connector));

        //then
        assertTrue(vault.isConnectorSupported(address(connector)));
    }

    function testShouldRemoveConnectorByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](1);
        AaveV3SupplyConnector connector = new AaveV3SupplyConnector(address(0x1), AAVE_V3_MARKET_ID);
        connectors[0] = address(connector);

        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

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

        assertTrue(vault.isConnectorSupported(address(connector)));

        //when
        vault.removeConnector(address(connector));

        //then
        assertFalse(vault.isConnectorSupported(address(connector)));
    }

    function testShouldSetupKeeperWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](0);
        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

        // when
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

        // then
        assertTrue(vault.isKeeperGranted(keeper));
    }

    function testShouldNotSetupKeeperWhenVaultIsCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](0);
        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

        // when
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

        // then
        assertFalse(vault.isKeeperGranted(address(0x2)));
    }

    function testShouldSetupKeeperByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory connectors = new address[](0);
        Vault.FuseStruct[] memory balanceConnectors = new Vault.FuseStruct[](0);

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

        //when
        vault.grantKeeper(address(0x2));

        //then
        assertTrue(vault.isKeeperGranted(address(0x2)));
    }
}
