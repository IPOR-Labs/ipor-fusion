// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlasmaVault} from "../../contracts/vaults/PlasmaVault.sol";
import {PlasmaVaultConfigLib} from "./../../contracts/libraries/PlasmaVaultConfigLib.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IporPriceOracleMock} from "../priceOracle/IporPriceOracleMock.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";

contract PlasmaVaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant USD = 0x0000000000000000000000000000000000000348;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public owner = address(this);

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);

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

    function testShouldSetupBalanceFusesWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        // then
        assertTrue(plasmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)));
    }

    function testShouldAddBalanceFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        assertFalse(
            plasmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should not be supported"
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
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        // then
        assertTrue(plasmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldAddFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        assertFalse(plasmaVault.isFuseSupported(address(fuse)));

        //when
        plasmaVault.addFuse(address(fuse));

        //then
        assertTrue(plasmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldAddFuseByOwnerAndExecuteAction() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
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

        deal(DAI, address(plasmaVault), amount);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)));

        // when
        plasmaVault.addFuse(address(supplyFuse));
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse)));
    }

    function testShouldAddFusesByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

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

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuse1);
        newSupplyFuses[1] = address(supplyFuse2);

        plasmaVault.addFuses(newSupplyFuses);

        //then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldAddFusesByOwnerAndExecuteAction() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlasmaVaultConfigLib.addressToBytes32(DAI);
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

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlasmaVault.FuseAction[] memory calls = new PlasmaVault.FuseAction[](2);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plasmaVault), 2 * amount);

        calls[0] = PlasmaVault.FuseAction(
            address(supplyFuse1),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        calls[1] = PlasmaVault.FuseAction(
            address(supplyFuse2),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));

        // when
        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuse1);
        newSupplyFuses[1] = address(supplyFuse2);
        plasmaVault.addFuses(newSupplyFuses);
        vm.prank(alpha);
        plasmaVault.execute(calls);

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldNotAddFuseWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

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

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.addFuse(address(supplyFuse));

        // then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse)));
    }

    function testShouldNotAddFusesWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

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

        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuse1);
        newSupplyFuses[1] = address(supplyFuse2);

        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.addFuses(newSupplyFuses);

        // then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldRemoveFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        assertTrue(plasmaVault.isFuseSupported(address(fuse)));

        //when
        plasmaVault.removeFuse(address(fuse));

        //then
        assertFalse(plasmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldRemoveFusesByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](2);
        initialSupplyFuses[0] = address(supplyFuse1);
        initialSupplyFuses[1] = address(supplyFuse2);

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

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        address[] memory newSupplyFuses = new address[](2);
        newSupplyFuses[0] = address(supplyFuse1);
        newSupplyFuses[1] = address(supplyFuse2);

        plasmaVault.removeFuses(newSupplyFuses);

        //then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldNotRemoveFuseWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

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

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.removeFuse(address(supplyFuse));

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse)));
    }

    function testShouldNotRemoveFusesWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory supplyFuses = new address[](2);
        supplyFuses[0] = address(supplyFuse1);
        supplyFuses[1] = address(supplyFuse2);

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

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.removeFuses(supplyFuses);

        // then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldAddAndRemoveFuseWhenOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuse1);

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

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        plasmaVault.addFuse(address(supplyFuse2));

        //then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        plasmaVault.removeFuse(address(supplyFuse1));

        //then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse1)));
    }

    function testShouldAddAndRemoveFusesWhenOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse supplyFuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse supplyFuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlasmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlasmaVault.MarketSubstratesConfig[](0);

        address[] memory initialSupplyFuses = new address[](1);
        initialSupplyFuses[0] = address(supplyFuse1);

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

        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        address[] memory newSupplyFuses = new address[](1);
        newSupplyFuses[0] = address(supplyFuse2);

        plasmaVault.addFuses(newSupplyFuses);

        //then
        assertTrue(plasmaVault.isFuseSupported(address(supplyFuse2)));

        //when
        plasmaVault.removeFuses(newSupplyFuses);

        //then
        assertFalse(plasmaVault.isFuseSupported(address(supplyFuse2)));
    }

    function testShouldSetupAlphaWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        // then
        assertTrue(plasmaVault.isAlphaGranted(alpha));
    }

    function testShouldNotSetupAlphaWhenVaultIsCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        // then
        assertFalse(plasmaVault.isAlphaGranted(address(0x2)));
    }

    function testShouldSetupAlphaByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        //when
        plasmaVault.grantAlpha(address(0x2));

        //then
        assertTrue(plasmaVault.isAlphaGranted(address(0x2)));
    }

    function testShouldAccessControlDeactivatedAfterCreateVault() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        // when
        bool isAccessControlActive = plasmaVault.isAccessControlActivated();

        // then

        assertFalse(isAccessControlActive);
    }

    function testShouldBeAbleToActivateAccessControl() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plasmaVault.activateAccessControl();

        // then
        assertTrue(plasmaVault.isAccessControlActivated());
        assertFalse(isAccessControlActiveBefore);
    }

    function testShouldNotBeAbleToActivateAccessControlWhenNotOwner() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plasmaVault.activateAccessControl();

        // then
        assertFalse(plasmaVault.isAccessControlActivated());
        assertFalse(isAccessControlActiveBefore);
    }

    function testShouldBeAbleToDeactivateAccessControl() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );
        vm.prank(owner);
        plasmaVault.activateAccessControl();

        bool isAccessControlActiveBefore = plasmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plasmaVault.deactivateAccessControl();

        // then
        assertFalse(plasmaVault.isAccessControlActivated());
        assertTrue(isAccessControlActiveBefore);
    }

    function testShouldNotBeAbleToDeactivateAccessControlWhenNotOwner() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
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
        assertTrue(plasmaVault.isAccessControlActivated());
        assertTrue(isAccessControlActiveBefore);
    }

    function testShouldBeAbleToUpdatePriceOracle() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        address newPriceOracle = address(new IporPriceOracleMock(USD, 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        // when
        plasmaVault.setPriceOracle(newPriceOracle);

        // then
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(priceOracleBefore, address(iporPriceOracleProxy));
        assertEq(priceOracleAfter, newPriceOracle);
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenDecimalIdWrong() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        address newPriceOracle = address(new IporPriceOracleMock(USD, 6, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracle(string)", Errors.PRICE_ORACLE_ERROR);

        // when
        vm.expectRevert(error);
        plasmaVault.setPriceOracle(newPriceOracle);

        // when
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(priceOracleBefore, address(iporPriceOracleProxy));
        assertEq(priceOracleAfter, address(iporPriceOracleProxy));
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenCurrencyIsWrong() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
        );

        address newPriceOracle = address(new IporPriceOracleMock(address(0x777), 8, address(0)));
        address priceOracleBefore = plasmaVault.getPriceOracle();

        bytes memory error = abi.encodeWithSignature("UnsupportedPriceOracle(string)", Errors.PRICE_ORACLE_ERROR);

        // when
        vm.expectRevert(error);
        plasmaVault.setPriceOracle(newPriceOracle);

        // when
        address priceOracleAfter = plasmaVault.getPriceOracle();

        assertEq(priceOracleBefore, address(iporPriceOracleProxy));
        assertEq(priceOracleAfter, address(iporPriceOracleProxy));
    }

    function testShouldNotBeAbleToUpdatePriceOracleWhenNotOwner() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

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
            address(0x777),
            0
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

        assertEq(priceOracleBefore, address(iporPriceOracleProxy));
        assertEq(priceOracleAfter, address(iporPriceOracleProxy));
    }
}
