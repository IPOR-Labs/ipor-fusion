// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";

contract IporPriceOracleMaintenanceTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant OWNER = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    IporPriceOracle private iporPriceOracleProxy;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 19574589);
        IporPriceOracle implementation = new IporPriceOracle(
            BASE_CURRENCY,
            BASE_CURRENCY_DECIMALS,
            CHAINLINK_FEED_REGISTRY
        );

        iporPriceOracleProxy = IporPriceOracle(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", OWNER)))
        );
    }

    function testShouldSetupInitialOwner() external {
        // when
        address owner = iporPriceOracleProxy.owner();

        // then
        assertEq(owner, OWNER, "Owner should be set correctly");
    }

    function testShouldNotBeAbleToSetBaseCurrencyAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "ZeroAddress(string,string)",
            Errors.ZERO_ADDRESS_NOT_SUPPORTED,
            "baseCurrency"
        );

        // when
        vm.expectRevert(error);
        new IporPriceOracle(address(0), BASE_CURRENCY_DECIMALS, CHAINLINK_FEED_REGISTRY);
    }

    function testShouldNotBeAbleToSetChainlinkFeedRegistryAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "ZeroAddress(string,string)",
            Errors.ZERO_ADDRESS_NOT_SUPPORTED,
            "chainlinkFeedRegistry"
        );

        // when
        vm.expectRevert(error);
        new IporPriceOracle(BASE_CURRENCY, BASE_CURRENCY_DECIMALS, address(0));
    }

    function testShouldNotBeAbleToSetAssetWithEmptyArrays() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "EmptyArrayNotSupported(string)",
            Errors.EMPTY_ARRAY_NOT_SUPPORTED
        );

        address[] memory assets = new address[](0);
        address[] memory sources = new address[](1);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldNotBeAbleToSetSourceWithEmptyArrays() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "EmptyArrayNotSupported(string)",
            Errors.EMPTY_ARRAY_NOT_SUPPORTED
        );

        address[] memory assets = new address[](1);
        assets[0] = address(0);
        address[] memory sources = new address[](0);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldNotBeAbleToSetAssetWithDifferentLengths() external {
        // given
        bytes memory error = abi.encodeWithSignature("ArrayLengthMismatch(string)", Errors.ARRAY_LENGTH_MISMATCH);

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](2);
        sources[0] = address(0);
        sources[1] = address(0);
        assets[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldNotBeAbleToSetAssetSourcesWhenSenderNotOwner() external {
        // given
        bytes memory error = abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this));

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(0);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldNotBeAbleToSetAssetAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "AssetsAddressCanNotBeZero(string)",
            Errors.ZERO_ADDRESS_NOT_SUPPORTED
        );

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(0);
        sources[0] = address(this);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldNotBeAbleToSetSourceAsZeroAddress() external {
        // given
        bytes memory error = abi.encodeWithSignature(
            "SourceAddressCanNotBeZero(string)",
            Errors.ZERO_ADDRESS_NOT_SUPPORTED
        );

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(this);
        sources[0] = address(0);

        // when
        vm.expectRevert(error);
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);
    }

    function testShouldBeAbleToSetupAssetAndSource() external {
        // given
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = address(this);
        sources[0] = address(this);

        // when
        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);

        // then
        assertEq(iporPriceOracleProxy.getSourceOfAsset(assets[0]), sources[0], "Source should be set correctly");
    }
}
