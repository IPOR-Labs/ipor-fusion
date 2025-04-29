// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPriceOracleMiddleware} from "contracts/price_oracle/IPriceOracleMiddleware.sol";
import {ERC4626PriceFeed} from "contracts/price_oracle/price_feed/ERC4626PriceFeed.sol";
import {IporFusionAccessControl} from "contracts/price_oracle/IporFusionAccessControl.sol";
import {PriceOracleMiddlewareWithRoles} from "contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
contract SUSDFPriceFeedTest is Test {
    address private constant SUSDF = 0xc8CF6D7991f15525488b2A83Df53468D682Ba4B0;
    address private constant USDF = 0xFa2B947eEc368f42195f24F36d2aF29f7c24CeC2;
    address private constant PRICE_ORACL = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;

    address private _admin;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22373579);

        ERC4626PriceFeed priceFeed = new ERC4626PriceFeed(SUSDF);

        _admin = IporFusionAccessControl(PRICE_ORACL).getRoleMember(keccak256("SET_ASSETS_PRICES_SOURCES"), 0);

        address[] memory assets_ = new address[](1);
        assets_[0] = SUSDF;
        address[] memory sources_ = new address[](1);
        sources_[0] = address(priceFeed);

        vm.startPrank(_admin);
        PriceOracleMiddlewareWithRoles(PRICE_ORACL).setAssetsPricesSources(assets_, sources_);
        vm.stopPrank();
    }

    function testAlwaysPasses() public {
        assertTrue(true, "Ten test zawsze przechodzi");
    }

    function testUSDFPrice() public {
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(PRICE_ORACL).getAssetPrice(USDF);

        assertEq(price, 1000041160000000000);
        assertEq(decimals, 18);
    }

    function testSUSDFPrice() public {
        (uint256 price, uint256 decimals) = IPriceOracleMiddleware(PRICE_ORACL).getAssetPrice(SUSDF);

        assertEq(price, 1028099478746381675);
        assertEq(decimals, 18);
    }
}
