// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPool} from "../../../contracts/vaults/interfaces/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/connectors/aave_v3/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/connectors/aave_v3/IAavePoolDataProvider.sol";
import {AaveV3SupplyConnector} from "../../../contracts/connectors/aave_v3/AaveV3SupplyConnector.sol";
import {VaultMock} from "./VaultMock.sol";

//https://mirror.xyz/unfrigginbelievable.eth/fzvIBwJZQKOP4sNpkrVZGOJEk5cDr6tarimQHTw6C84
contract ForkAmmGovernanceServiceTest is Test {
    struct SupportedToken {
        address token;
        string name;
    }

    IPool public constant AAVE_POOL = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    SupportedToken private activeTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"));
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        AaveV3SupplyConnector connector = new AaveV3SupplyConnector(address(AAVE_POOL), 1);
        VaultMock vaultMock = new VaultMock(address(connector));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.token).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;
        vaultMock.grantAssetsToMarket(connector.MARKET_ID(), assets);

        // when

        vaultMock.enter(
            AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                token: activeTokens.token,
                amount: amount,
                userEModeCategoryId: uint256(300)
            })
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.token).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.token);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= amount,
            "aToken balance should be increased by amount"
        );
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "stableDebtToken balance should be 0");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV3SupplyConnector connector = new AaveV3SupplyConnector(address(AAVE_POOL), 1);
        VaultMock vaultMock = new VaultMock(address(connector));

        uint256 decimals = ERC20(activeTokens.token).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.token, address(vaultMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.token).balanceOf(address(vaultMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.token;
        vaultMock.grantAssetsToMarket(connector.MARKET_ID(), assets);

        vaultMock.enter(
            AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                token: activeTokens.token,
                amount: enterAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // when

        vaultMock.exit(
            AaveV3SupplyConnector.AaveV3SupplyConnectorData({
                token: activeTokens.token,
                amount: exitAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.token).balanceOf(address(vaultMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.token);

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(vaultMock)) >= enterAmount - exitAmount - dustOnAToken,
            "aToken balance should be decreased by amount"
        );
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(vaultMock)), 0, "stableDebtToken balance should be 0");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(vaultMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function _getSupportedAssets() private returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](22);

        supportedTokensTemp[0] = SupportedToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2, "WETH");
        supportedTokensTemp[1] = SupportedToken(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0, "WSTETH");
        supportedTokensTemp[2] = SupportedToken(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599, "WBTC");
        supportedTokensTemp[3] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[4] = SupportedToken(0x514910771AF9Ca656af840dff83E8264EcF986CA, "LINK");
        supportedTokensTemp[5] = SupportedToken(0xBe9895146f7AF43049ca1c1AE358B0541Ea49704, "cbETH");
        supportedTokensTemp[6] = SupportedToken(0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT");
        supportedTokensTemp[7] = SupportedToken(0xae78736Cd615f374D3085123A210448E74Fc6393, "rETH");
        supportedTokensTemp[8] = SupportedToken(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0, "LUSD");
        supportedTokensTemp[9] = SupportedToken(0xD533a949740bb3306d119CC777fa900bA034cd52, "CRV");
        supportedTokensTemp[10] = SupportedToken(0x9f8F72aA9304c8B593d555F12eF6589cC3A579A2, "MKR");
        supportedTokensTemp[11] = SupportedToken(0xba100000625a3754423978a60c9317c58a424e3D, "BAL");
        supportedTokensTemp[12] = SupportedToken(0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984, "UNI");
        supportedTokensTemp[13] = SupportedToken(0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72, "ENS");
        supportedTokensTemp[14] = SupportedToken(0x111111111117dC0aa78b770fA6A738034120C302, "1INCH");
        supportedTokensTemp[15] = SupportedToken(0x853d955aCEf822Db058eb8505911ED77F175b99e, "FRAX");
        supportedTokensTemp[16] = SupportedToken(0xD33526068D116cE69F19A9ee46F0bd304F21A51f, "RPL");
        supportedTokensTemp[17] = SupportedToken(0x83F20F44975D03b1b09e64809B757c47f942BEeA, "sDAI");
        supportedTokensTemp[18] = SupportedToken(0xAf5191B0De278C7286d6C7CC6ab6BB8A73bA2Cd6, "STG");
        supportedTokensTemp[19] = SupportedToken(0xdeFA4e8a7bcBA345F687a2f1456F5Edd9CE97202, "KNC");
        supportedTokensTemp[20] = SupportedToken(0xf939E0A03FB07F59A73314E73794Be0E57ac1b4E, "crvUSD");
        supportedTokensTemp[21] = SupportedToken(0x6c3ea9036406852006290770BEdFcAbA0e23A0e8, "PYUSD");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        deal(asset, to, amount);
    }

    modifier iterateSupportedTokens() {
        SupportedToken[] memory supportedTokens = _getSupportedAssets();
        for (uint256 i; i < supportedTokens.length; i++) {
            activeTokens = supportedTokens[i];
            _;
        }
    }
}