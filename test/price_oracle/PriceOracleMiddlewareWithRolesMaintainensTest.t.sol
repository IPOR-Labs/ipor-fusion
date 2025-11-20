// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";

contract PriceOracleMiddlewareMaintenanceTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant ADMIN = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddlewareWithRoles private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19574589);
        PriceOracleMiddlewareWithRoles implementation = new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY);

        priceOracleMiddlewareProxy = PriceOracleMiddlewareWithRoles(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.grantRole(priceOracleMiddlewareProxy.SET_ASSETS_PRICES_SOURCES(), ADMIN);
        vm.stopPrank();
    }

    function testShouldSetupInitialOwner() external view {
        // when
        bool isAdmin = priceOracleMiddlewareProxy.hasRole(priceOracleMiddlewareProxy.DEFAULT_ADMIN_ROLE(), ADMIN);

        // then
        assertEq(isAdmin, true, "Admin should be set correctly");
    }

    function testShouldNotBeAbleToSetAssetWithEmptyArrays() external {
        // given
        bytes memory error = abi.encodeWithSignature("EmptyArrayNotSupported()");

        address[] memory assets = new address[](0);
        address[] memory sources = new address[](1);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleToSetSourceWithEmptyArrays() external {
        // given
        bytes memory error = abi.encodeWithSignature("EmptyArrayNotSupported()");

        address[] memory assets = new address[](1);
        assets[0] = address(0);
        address[] memory sources = new address[](0);

        // when
        vm.expectRevert(error);
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleToSetAssetWithDifferentLengths() external {
        // given
        bytes memory error = abi.encodeWithSignature("ArrayLengthMismatch()");

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](2);
        sources[0] = address(0);
        sources[1] = address(0);
        assets[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleTosetAssetsPricesSourcesWhenSenderNotAdmin() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "AccessControlUnauthorizedAccount(address,bytes32)",
            address(this),
            priceOracleMiddlewareProxy.SET_ASSETS_PRICES_SOURCES()
        );

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(0);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleToSetAssetAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature("AssetsAddressCanNotBeZero()");

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(0);
        sources[0] = address(this);

        // when
        vm.expectRevert(error);
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleToSetSourceAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature("SourceAddressCanNotBeZero()");

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(this);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldBeAbleToSetupAssetAndSource() external {
        // given
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(this);
        sources[0] = address(this);

        // when
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        // then
        assertEq(
            priceOracleMiddlewareProxy.getSourceOfAssetPrice(assets[0]),
            sources[0],
            "Source should be set correctly"
        );
    }
}
