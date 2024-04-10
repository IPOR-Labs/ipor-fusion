// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {PlazmaVaultFactory} from "../../contracts/vaults/PlazmaVaultFactory.sol";
import {PlazmaVault} from "../../contracts/vaults/PlazmaVault.sol";
import {AaveV3SupplyFuse} from "../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3BalanceFuse} from "../../contracts/fuses/aave_v3/AaveV3BalanceFuse.sol";
import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract PlazmaVaultMaintenanceTest is Test {
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
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

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

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

        AaveV3BalanceFuse balanceFuse = new AaveV3BalanceFuse(AAVE_V3_MARKET_ID);

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
        plazmaVault.addBalanceFuse(PlazmaVault.MarketBalanceFuseConfig(AAVE_V3_MARKET_ID, address(balanceFuse)));

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
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);
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

        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);

        assertFalse(plazmaVault.isFuseSupported(address(fuse)));

        //when
        plazmaVault.addFuse(address(fuse));

        //then
        assertTrue(plazmaVault.isFuseSupported(address(fuse)));
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
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(address(0x1), AAVE_V3_MARKET_ID);
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
}
