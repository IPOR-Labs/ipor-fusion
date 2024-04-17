// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IAavePriceOracle} from "../../../contracts/fuses/aave_v3/IAavePriceOracle.sol";
import {AaveLendingPoolV2, ReserveData} from "../../../contracts/fuses/aave_v2/AaveLendingPoolV2.sol";
import {AaveV2SupplyFuse, AaveV2SupplyFuseEnterData, AaveV2SupplyFuseExitData} from "../../../contracts/fuses/aave_v2/AaveV2SupplyFuse.sol";
import {AaveV2SupplyFuseMock} from "./AaveV2SupplyFuseMock.sol";
import {ILendingPoolAddressesProvider} from "./ILendingPoolAddressesProvider.sol";

contract AaveV2SupplyFuseTest is Test {
    struct SupportedToken {
        address asset;
        string name;
    }

    AaveLendingPoolV2 public constant AAVE_POOL = AaveLendingPoolV2(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);
    IAavePriceOracle public constant AAVE_PRICE_ORACLE = IAavePriceOracle(0x54586bE62E3c3580375aE3723C145253060Ca0C2);
    ILendingPoolAddressesProvider public constant AAVE_POOL_DATA_PROVIDER =
        ILendingPoolAddressesProvider(0xB53C1a33016B2DC2fF3653530bfF1848a515c8c5);

    SupportedToken private activeTokens;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19591360);
    }

    function testShouldBeAbleToSupply() external iterateSupportedTokens {
        // given
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock fuseMock = new AaveV2SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 amount = 100 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        // when

        fuseMock.enter(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));
        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;
        address stableDebtTokenAddress = reserveData.stableDebtTokenAddress;
        address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

        assertApproxEqAbs(balanceAfter + amount, balanceBefore, 100, "vault balance should be decreased by amount");
        assertApproxEqAbs(
            ERC20(aTokenAddress).balanceOf(address(fuseMock)),
            amount,
            100,
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
        AaveV2SupplyFuse fuse = new AaveV2SupplyFuse(1, address(AAVE_POOL));
        AaveV2SupplyFuseMock fuseMock = new AaveV2SupplyFuseMock(address(fuse));

        uint256 decimals = ERC20(activeTokens.asset).decimals();
        uint256 enterAmount = 100 * 10 ** decimals;
        uint256 exitAmount = 50 * 10 ** decimals;

        _supplyTokensToMockVault(activeTokens.asset, address(fuseMock), 1_000 * 10 ** decimals);

        uint256 balanceBefore = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        address[] memory assets = new address[](1);
        assets[0] = activeTokens.asset;
        fuseMock.grantAssetsToMarket(fuse.MARKET_ID(), assets);

        fuseMock.enter(AaveV2SupplyFuseEnterData({asset: activeTokens.asset, amount: enterAmount}));

        // when

        fuseMock.exit(AaveV2SupplyFuseExitData({asset: activeTokens.asset, amount: exitAmount}));

        // then
        uint256 balanceAfter = ERC20(activeTokens.asset).balanceOf(address(fuseMock));

        ReserveData memory reserveData = AAVE_POOL.getReserveData(activeTokens.asset);

        address aTokenAddress = reserveData.aTokenAddress;
        address stableDebtTokenAddress = reserveData.stableDebtTokenAddress;
        address variableDebtTokenAddress = reserveData.variableDebtTokenAddress;

        assertEq(balanceAfter + enterAmount - exitAmount, balanceBefore, "vault balance should be decreased by amount");
        assertApproxEqAbs(
            ERC20(aTokenAddress).balanceOf(address(fuseMock)),
            enterAmount - exitAmount,
            dustOnAToken,
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
        supportedTokensTemp = new SupportedToken[](2);

        supportedTokensTemp[0] = SupportedToken(0x6B175474E89094C44Da98b954EedeAC495271d0F, "DAI");
        supportedTokensTemp[1] = SupportedToken(0xdAC17F958D2ee523a2206206994597C13D831ec7, "USDT");
    }

    function _supplyTokensToMockVault(address asset, address to, uint256 amount) private {
        if (asset == 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48) {
            // USDC
            vm.prank(0x137000352B4ed784e8fa8815d225c713AB2e7Dc9); // AmmTreasuryUsdcProxy
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
