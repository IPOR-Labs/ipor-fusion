// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/price_oracle/PriceOracleMiddleware.sol";

contract PriceOracleMiddlewareMaintenanceTest is Test {
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;
    address public constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address public constant CHAINLINK_USDC_USD = 0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 202220653);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(address(0));

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = USDC;
        sources[0] = CHAINLINK_USDC_USD;

        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldReturnSDaiPrice() external {
        // given

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(USDC);

        // then
        assertEq(result, uint256(1 * 10 ** decimals), "Price should be calculated correctly");
    }

    function testShouldRevertWhenPassNotSupportedAsset() external {
        // given
        bytes memory error = abi.encodeWithSignature("UnsupportedAsset()");
        address dai = 0xDA10009cBd5D07dd0CeCc66161FC93D7c9000da1;
        // when
        vm.expectRevert(error);
        priceOracleMiddlewareProxy.getAssetPrice(dai);
    }
}
