// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlazmaVaultFactory} from "../../contracts/vaults/PlazmaVaultFactory.sol";
import {PlazmaVaultConfigLib} from "../../contracts/libraries/PlazmaVaultConfigLib.sol";
import {PlazmaVault} from "../../contracts/vaults/PlazmaVault.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PlazmaVaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    /// @dev Aave Price Oracle mainnet address where base currency is USD
    address public constant ETHEREUM_AAVE_PRICE_ORACLE_MAINNET = 0x54586bE62E3c3580375aE3723C145253060Ca0C2;
    address public constant ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3 = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    PlazmaVaultFactory internal vaultFactory;

    uint256 public constant AAVE_V3_MARKET_ID = 1;

    address public owner = address(this);

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
        vaultFactory = new PlazmaVaultFactory(owner);
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        // when
        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        // then
        assertTrue(plazmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)));
    }

    function testShouldAddBalanceFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(
            plazmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
            "Balance fuse should not be supported"
        );

        //when
        plazmaVault.addBalanceFuse(AAVE_V3_MARKET_ID, address(balanceFuse));

        //then
        assertTrue(
            plazmaVault.isBalanceFuseSupported(AAVE_V3_MARKET_ID, address(balanceFuse)),
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        // then
        assertTrue(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldAddFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        assertFalse(plazmaVault.isFuseSupported(address(fuse)));

        //when
        plazmaVault.addFuse(address(fuse));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldAddFuseByOwnerAndExecuteAction() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory supplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    supplyFuses,
                    balanceFuses
                )
            )
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(supplyFuse)));

        // when
        plazmaVault.addFuse(address(supplyFuse));

        // then
        assertTrue(plazmaVault.isFuseSupported(address(supplyFuse)));

        // when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        // then
        assertTrue(true);
    }

    function testShouldAddFusesByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));

        //when
        plazmaVault.addFuse(address(fuse1));
        plazmaVault.addFuse(address(fuse2));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldAddFusesByOwnerAndExecuteAction() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory fuses = new address[](0);

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
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

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](2);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), 2 * amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse1),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        calls[1] = PlazmaVault.FuseAction(
            address(supplyFuse2),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(supplyFuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(supplyFuse2)));

        // when
        plazmaVault.addFuse(address(supplyFuse1));
        plazmaVault.addFuse(address(supplyFuse2));

        // then
        assertTrue(plazmaVault.isFuseSupported(address(supplyFuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(supplyFuse2)));

        // when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        // then
        assertTrue(true);
    }

    function testShouldAddFuseByOwnerAndExecuteAction() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](1);
        bytes32[] memory assets = new bytes32[](1);
        assets[0] = PlazmaVaultConfigLib.addressToBytes32(DAI);
        marketConfigs[0] = PlazmaVault.MarketSubstratesConfig(AAVE_V3_MARKET_ID, assets);

        address[] memory supplyFuses = new address[](0);
        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(
            AAVE_V3_MARKET_ID,
            ETHEREUM_AAVE_PRICE_ORACLE_MAINNET,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](1);
        balanceFuses[0] = PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse));

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    supplyFuses,
                    balanceFuses
                )
            )
        );

        AaveV3SupplyFuse supplyFuse = new AaveV3SupplyFuse(
            AAVE_V3_MARKET_ID,
            AAVE_POOL,
            ETHEREUM_AAVE_POOL_DATA_PROVIDER_V3
        );

        PlazmaVault.FuseAction[] memory calls = new PlazmaVault.FuseAction[](1);

        uint256 amount = 100 * 1e18;

        deal(DAI, address(plazmaVault), amount);

        calls[0] = PlazmaVault.FuseAction(
            address(supplyFuse),
            abi.encodeWithSignature(
                "enter(bytes)",
                abi.encode(AaveV3SupplyFuseEnterData({asset: DAI, amount: amount, userEModeCategoryId: 1e18}))
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(supplyFuse)));

        // when
        plazmaVault.addFuse(address(supplyFuse));

        // then
        assertTrue(plazmaVault.isFuseSupported(address(supplyFuse)));

        // when
        vm.prank(alpha);
        plazmaVault.execute(calls);

        // // then
        // assertTrue(true);
    }

    function testShouldAddFusesByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));

        //when
        plazmaVault.addFuse(address(fuse1));
        plazmaVault.addFuse(address(fuse2));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldNotAddFuseWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        assertFalse(plazmaVault.isFuseSupported(address(fuse)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        //when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plazmaVault.addFuse(address(fuse));

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldNotAddFusesWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        //when
        vm.startPrank(address(0x777));
        vm.expectRevert(error);
        plazmaVault.addFuse(address(fuse1));
        vm.expectRevert(error);
        plazmaVault.addFuse(address(fuse2));
        vm.stopPrank();

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldRemoveFuseByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        fuses[0] = address(fuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertTrue(plazmaVault.isFuseSupported(address(fuse)));

        //when
        plazmaVault.removeFuse(address(fuse));

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldRemoveFusesByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](2);
        fuses[0] = address(fuse1);
        fuses[1] = address(fuse2);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));

        //when
        plazmaVault.removeFuse(address(fuse1));
        plazmaVault.removeFuse(address(fuse2));

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldNotRemoveFuseWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](1);
        fuses[0] = address(fuse);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertTrue(plazmaVault.isFuseSupported(address(fuse)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        //when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plazmaVault.removeFuse(address(fuse));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldNotRemoveFusesWhenNotOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](2);
        fuses[0] = address(fuse1);
        fuses[1] = address(fuse2);

        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        //when
        vm.startPrank(address(0x777));
        vm.expectRevert(error);
        plazmaVault.removeFuse(address(fuse1));
        vm.expectRevert(error);
        plazmaVault.removeFuse(address(fuse2));
        vm.stopPrank();

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldAddAndRemoveFuseWhenOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(fuse)));

        //when
        plazmaVault.addFuse(address(fuse));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse)));

        //when
        plazmaVault.removeFuse(address(fuse));

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse)));
    }

    function testShouldAddAndRemoveFusesWhenOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;

        address[] memory alphas = new address[](1);
        address alpha = address(0x1);
        alphas[0] = alpha;

        AaveV3SupplyFuse fuse1 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x1), address(0x1));
        AaveV3SupplyFuse fuse2 = new AaveV3SupplyFuse(AAVE_V3_MARKET_ID, address(0x2), address(0x2));

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));

        //when
        plazmaVault.addFuse(address(fuse1));
        plazmaVault.addFuse(address(fuse2));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse1)));
        assertTrue(plazmaVault.isFuseSupported(address(fuse2)));

        //when
        plazmaVault.removeFuse(address(fuse1));
        plazmaVault.removeFuse(address(fuse2));

        //then
        assertFalse(plazmaVault.isFuseSupported(address(fuse1)));
        assertFalse(plazmaVault.isFuseSupported(address(fuse2)));
    }

    function testShouldSetupAlphaWhenVaultCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        // then
        assertTrue(plazmaVault.isAlphaGranted(alpha));
    }

    function testShouldNotSetupAlphaWhenVaultIsCreated() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        // when
        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        // then
        assertFalse(plazmaVault.isAlphaGranted(address(0x2)));
    }

    function testShouldSetupAlphaByOwner() public {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        //when
        plazmaVault.grantAlpha(address(0x2));

        //then
        assertTrue(plazmaVault.isAlphaGranted(address(0x2)));
    }

    function testShouldAccessControlDeactivatedAfterCreateVault() external {
        // given
        string memory assetName = "IPOR Fusion DAI";
        string memory assetSymbol = "ipfDAI";
        address underlyingToken = DAI;
        address[] memory alphas = new address[](1);

        address alpha = address(0x1);
        alphas[0] = alpha;

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        // when
        bool isAccessControlActive = plazmaVault.isAccessControlActivated();

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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        bool isAccessControlActiveBefore = plazmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plazmaVault.activateAccessControl();

        // then
        assertTrue(plazmaVault.isAccessControlActivated());
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );

        bool isAccessControlActiveBefore = plazmaVault.isAccessControlActivated();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plazmaVault.activateAccessControl();

        // then
        assertFalse(plazmaVault.isAccessControlActivated());
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );
        vm.prank(owner);
        plazmaVault.activateAccessControl();

        bool isAccessControlActiveBefore = plazmaVault.isAccessControlActivated();

        // when
        vm.prank(owner);
        plazmaVault.deactivateAccessControl();

        // then
        assertFalse(plazmaVault.isAccessControlActivated());
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

        PlazmaVault.MarketSubstratesConfig[] memory marketConfigs = new PlazmaVault.MarketSubstratesConfig[](0);

        address[] memory fuses = new address[](0);
        PlazmaVault.MarketBalanceFuseConfig[] memory balanceFuses = new PlazmaVault.MarketBalanceFuseConfig[](0);

        PlazmaVault plazmaVault = PlazmaVault(
            payable(
                vaultFactory.createVault(
                    assetName,
                    assetSymbol,
                    underlyingToken,
                    address(iporPriceOracleProxy),
                    alphas,
                    marketConfigs,
                    fuses,
                    balanceFuses
                )
            )
        );
        vm.prank(owner);
        plazmaVault.activateAccessControl();

        bool isAccessControlActiveBefore = plazmaVault.isAccessControlActivated();

        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(0x777));

        // when
        vm.expectRevert(error);
        vm.prank(address(0x777));
        plazmaVault.deactivateAccessControl();

        // then
        assertTrue(plazmaVault.isAccessControlActivated());
        assertTrue(isAccessControlActiveBefore);
    }
}
