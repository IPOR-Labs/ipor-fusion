// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {VaultFactory} from "../../contracts/vaults/VaultFactory.sol";
import {Vault} from "../../contracts/vaults/Vault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";

contract VaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    VaultFactory internal vaultFactory;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public owner = address(this);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new VaultFactory(owner);
    }

    function testShouldSetupBalanceFusesWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](0);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](1);
        balanceFuses[0] = Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuse));

        // when
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

        // then
        assertTrue(vault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)));
    }

    function testShouldAddBalanceFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

        address[] memory fuses = new address[](0);
        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

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

        assertFalse(
            vault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should not be supported"
        );

        //when
        vault.addBalanceFuse(Vault.FuseStruct(AAVE_V3_MARKET_ID, address(balanceFuse)));

        //then
        assertTrue(
            vault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should be supported"
        );
    }

    function testShouldSetupFusesWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);
        fuses[0] = address(fuse);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

        // when
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

        // then
        assertTrue(vault.isFuseSupported(address(fuse)));
    }

    function testShouldAddFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory fuses = new address[](0);
        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

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

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);

        assertFalse(vault.isFuseSupported(address(fuse)));

        //when
        vault.addFuse(address(fuse));

        //then
        assertTrue(vault.isFuseSupported(address(fuse)));
    }

    function testShouldRemoveFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory keepers = new address[](1);

        address keeper = address(0x1);
        keepers[0] = keeper;

        Vault.MarketConfig[] memory marketConfigs = new Vault.MarketConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);
        fuses[0] = address(fuse);

        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

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

        assertTrue(vault.isFuseSupported(address(fuse)));

        //when
        vault.removeFuse(address(fuse));

        //then
        assertFalse(vault.isFuseSupported(address(fuse)));
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

        address[] memory fuses = new address[](0);
        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

        // when
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

        address[] memory fuses = new address[](0);
        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

        // when
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

        address[] memory fuses = new address[](0);
        Vault.FuseStruct[] memory balanceFuses = new Vault.FuseStruct[](0);

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

        //when
        vault.grantKeeper(address(0x2));

        //then
        assertTrue(vault.isKeeperGranted(address(0x2)));
    }
}
