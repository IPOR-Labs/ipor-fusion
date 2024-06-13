// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IPool} from "../../../contracts/vaults/interfaces/IPool.sol";
import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/ext/IAavePriceOracle.sol";
import {IAavePoolDataProvider} from "../../../contracts/fuses/aave_v3/ext/IAavePoolDataProvider.sol";
import {AaveV3SupplyFuse, AaveV3SupplyFuseEnterData, AaveV3SupplyFuseExitData} from "../../../contracts/fuses/aave_v3/AaveV3SupplyFuse.sol";
import {AaveV3SupplyFuseMock} from "./AaveV3SupplyFuseMock.sol";

contract AaveV3SupplyFuseArbitrumTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    IPool public constant AAVE_POOL = IPool(0x794a61358D6845594F94dc1DB02A252b5b4814aD);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0xb56c2F0B653B2e0b10C9b928C8580Ac5Df02C7C7);
    IAavePoolDataProvider public constant AAVE_POOL_DATA_PROVIDER =
        IAavePoolDataProvider(0x69FA688f1Dc47d4B5d8029D5a35FB7a548310654);

    SupportedToken private activeTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, address(AAVE_POOL), address(AAVE_POOL_DATA_PROVIDER));
        AaveV3SupplyFuseMock fuseMock = new AaveV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when

        fuseMock.enter(
            AaveV3SupplyFuseEnterData({asset: activeTokens.asset, amount: amount, userEModeCategoryId: uint256(300)})
        );

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(fuseMock)) >= amount,
            "aToken balance should be increased by amount"
        );
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(fuseMock)), 0, "stableDebtToken balance should be 0");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(fuseMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function testShouldBeAbleToWithdraw() external iterateSupportedTokens {
        // given
        uint256 dustOnAToken = 10;
        AaveV3SupplyFuse fuse = new AaveV3SupplyFuse(1, address(AAVE_POOL), address(AAVE_POOL_DATA_PROVIDER));
        AaveV3SupplyFuseMock fuseMock = new AaveV3SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        fuseMock.enter(
            AaveV3SupplyFuseEnterData({
                asset: activeTokens.asset,
                amount: enterAmount,
                userEModeCategoryId: uint256(300)
            })
        );

        // when

        fuseMock.exit(AaveV3SupplyFuseExitData({asset: activeTokens.asset, amount: exitAmount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        (
            address aTokenAddress,
            address stableDebtTokenAddress,
            address variableDebtTokenAddress
        ) = AAVE_POOL_DATA_PROVIDER.getReserveTokensAddresses(activeTokens.asset);

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(
            ERC20(aTokenAddress).balanceOf(address(fuseMock)) >= enterAmount - exitAmount - dustOnAToken,
            "aToken balance should be decreased by amount"
        );
        assertEq(ERC20(stableDebtTokenAddress).balanceOf(address(fuseMock)), 0, "stableDebtToken balance should be 0");
        assertEq(
            ERC20(variableDebtTokenAddress).balanceOf(address(fuseMock)),
            0,
            "variableDebtToken balance should be 0"
        );
    }

    function _getSupportedAssets() private pure returns (SupportedToken[] memory supportedTokensTemp) {
        supportedTokensTemp = new SupportedToken[](1);

        supportedTokensTemp[0] = SupportedToken(0xaf88d065e77c8cC2239327C5EDb3A432268e5831, "USDC");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xaf88d065e77c8cC2239327C5EDb3A432268e5831) {
            // USDC
            vm.prank(0x05e3a758FdD29d28435019ac453297eA37b61b62); // holder
            ERC20(asset).transfer(to, amount);
        } else {
            deal(asset, to, amount);
        }
    }

    modifier iterateSupportedTokens() {
        SupportedToken[] memory supportedTokens = _getSupportedAssets();
        for (uint256 i; i < supportedTokens.length; ++i) {
            activeTokens = supportedTokens[i];
            _;
        }
    }
}
