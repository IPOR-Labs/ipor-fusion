// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddleware} from "../../contracts/priceOracle/PriceOracleMiddleware.sol";

contract PriceOracleMiddlewareMaintenanceTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddleware private priceOracleMiddlewareProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19574589);
        PriceOracleMiddleware implementation = new PriceOracleMiddleware(
            BASE_CURRENCY,
            BASE_CURRENCY_DECIMALS,
            CHAINLINK_FEED_REGISTRY
        );

        priceOracleMiddlewareProxy = PriceOracleMiddleware(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
    }

    function testShouldSetupInitialOwner() external {
        // when
        address owner = priceOracleMiddlewareProxy.owner();

        // then
        assertEq(owner, OWNER, "Owner should be set correctly");
    }

    function testShouldNotBeAbleToSetBaseCurrencyAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature("ZeroAddress(string)", "baseCurrency");

        // when
        vm.expectRevert(error);
        new PriceOracleMiddleware(address(0), BASE_CURRENCY_DECIMALS, CHAINLINK_FEED_REGISTRY);
    }

    function testShouldNotBeAbleToSetAssetWithEmptyArrays() external {
        // given
        bytes memory error = abi.encodeWithSignature("EmptyArrayNotSupported()");

        address[] memory assets = new address[](0);
        address[] memory sources = new address[](1);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
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
        vm.prank(OWNER);
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
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldNotBeAbleTosetAssetsPricesSourcesWhenSenderNotOwner() external {
        // given
        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this));

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
        vm.prank(OWNER);
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
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
    }

    function testShouldBeAbleToSetupAssetAndSource() external {
        // given
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(this);
        sources[0] = address(this);

        // when
        vm.prank(OWNER);
        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);

        // then
        assertEq(
            priceOracleMiddlewareProxy.getSourceOfAssetPrice(assets[0]),
            sources[0],
            "Source should be set correctly"
        );
    }
}
