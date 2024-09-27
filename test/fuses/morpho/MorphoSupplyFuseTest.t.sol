// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {MorphoSupplyFuse, MorphoSupplyFuseExitData, MorphoSupplyFuseEnterData} from "../../../contracts/fuses/morpho/MorphoSupplyFuse.sol";
import {MorphoBalanceFuse} from "../../../contracts/fuses/morpho/MorphoBalanceFuse.sol";
import {IMorpho, MarketParams, Id} from "@morpho-org/morpho-blue/src/interfaces/IMorpho.sol";
import {MorphoBalancesLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoBalancesLib.sol";
import {SharesMathLib} from "@morpho-org/morpho-blue/src/libraries/SharesMathLib.sol";
import {MarketParamsLib} from "@morpho-org/morpho-blue/src/libraries/MarketParamsLib.sol";
import {MorphoLib} from "@morpho-org/morpho-blue/src/libraries/periphery/MorphoLib.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {PlasmaVaultMock} from "../PlasmaVaultMock.sol";

contract MorphoSupplyFuseTest is Test {
    using MorphoBalancesLib for IMorpho;
    using MorphoLib for IMorpho;
    using SharesMathLib for uint256;
    using MarketParamsLib for MarketParams;

    address private constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    IMorpho public constant MORPHO = IMorpho(0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb);
    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19538857);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(
                new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", address(this)))
            )
        );
    }

    function testShouldBeAbleToSupplyDaiToMorpho() external {
        // given
        // sDAI/DAI
        bytes32 marketIdBytes32 = 0xb1eac1c0f3ad13fb45b01beac8458c055c903b1bff8cb882346635996a774f77;
        Id marketId = Id.wrap(marketIdBytes32);

        MorphoBalanceFuse balanceFuse = new MorphoBalanceFuse(1);
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(balanceFuse));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        MarketParams memory marketParams = MORPHO.idToMarketParams(marketId);

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceOnMorphoBefore = MORPHO.expectedSupplyAssets(marketParams, address(vaultMock));
        uint256 balanceFromBalanceFuseBefore = vaultMock.balanceOf();

        bytes32[] memory marketIds = new bytes32[](1);
        marketIds[0] = marketIdBytes32;
        vaultMock.grantMarketSubstrates(fuse.MARKET_ID(), marketIds);

        // when
        vaultMock.enterMorphoSupply(MorphoSupplyFuseEnterData({morphoMarketId: marketIdBytes32, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceOnMorphoAfter = MORPHO.expectedSupplyAssets(marketParams, address(vaultMock));
        uint256 balanceFromBalanceFuseAfter = vaultMock.balanceOf();

        assertEq(balanceFromBalanceFuseAfter, 100042570999999999998, "balance should be 100042570999999999998");
        assertEq(balanceFromBalanceFuseBefore, uint256(0), "balance should be 0");

        assertEq(balanceAfter + amount, balanceBefore, "vault balance should be decreased by amount");
        assertTrue(balanceOnMorphoAfter > balanceOnMorphoBefore, "collateral balance should be increased by amount");
    }

    function testShouldBeAbleToWithdrawDaiToMorpho() external {
        // given
        // sDAI/DAI
        bytes32 marketIdBytes32 = 0xb1eac1c0f3ad13fb45b01beac8458c055c903b1bff8cb882346635996a774f77;
        Id marketId = Id.wrap(marketIdBytes32);
        MorphoSupplyFuse fuse = new MorphoSupplyFuse(1);
        PlasmaVaultMock vaultMock = new PlasmaVaultMock(address(fuse), address(0));
        vaultMock.setPriceOracleMiddleware(address(priceOracleMiddlewareProxy));

        uint256 amount = 100e18;

        deal(DAI, address(vaultMock), 1_000e18);

        MarketParams memory marketParams = MORPHO.idToMarketParams(marketId);

        bytes32[] memory marketIds = new bytes32[](1);
        marketIds[0] = marketIdBytes32;
        vaultMock.grantMarketSubstrates(fuse.MARKET_ID(), marketIds);

        vaultMock.enterMorphoSupply(MorphoSupplyFuseEnterData({morphoMarketId: marketIdBytes32, amount: amount}));

        uint256 balanceBefore = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceOnMorphoBefore = MORPHO.expectedSupplyAssets(marketParams, address(vaultMock));

        // when
        vaultMock.exitMorphoSupply(MorphoSupplyFuseExitData({morphoMarketId: marketIdBytes32, amount: amount}));

        // then
        uint256 balanceAfter = ERC20(DAI).balanceOf(address(vaultMock));
        uint256 balanceOnMorphoAfter = MORPHO.expectedSupplyAssets(marketParams, address(vaultMock));

        assertGt(balanceAfter, balanceBefore, "vault balance should be increased ");
        assertTrue(balanceOnMorphoAfter < balanceOnMorphoBefore, "collateral balance should be decreased");
    }
}
