// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {IporPriceOracle} from "../../contracts/priceOracle/IporPriceOracle.sol";
import {Errors} from "../../contracts/libraries/errors/Errors.sol";
import "../../contracts/priceOracle/priceFeed/SDaiPriceFeed.sol";

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

    function testShouldRevertWhenPassNotSupportetAsset() external {
        // given
        bytes memory error = abi.encodeWithSignature("UnsupportedAsset(string)", Errors.UNSUPPORTED_ASSET);

        // when
        vm.expectRevert(error);
        iporPriceOracleProxy.getAssetPrice(address(0));
    }

    function testShouldReturnDaiPrice() external {
        // given
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

        // when
        uint256 result = iporPriceOracleProxy.getAssetPrice(dai);

        // then
        assertEq(result, uint256(99984808), "Price should be calculated correctly");
    }

    function testShouldReturnUsdcPrice() external {
        // given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // when
        uint256 result = iporPriceOracleProxy.getAssetPrice(usdc);

        // then
        assertEq(result, uint256(99995746), "Price should be calculated correctly");
    }

    function testShouldReturnUsdtPrice() external {
        // given
        address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

        // when
        uint256 result = iporPriceOracleProxy.getAssetPrice(usdt);

        // then
        assertEq(result, uint256(99975732), "Price should be calculated correctly");
    }

    function testShouldReturnEthPrice() external {
        // given
        address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // when
        uint256 result = iporPriceOracleProxy.getAssetPrice(eth);

        // then
        assertEq(result, uint256(334937530000), "Price should be calculated correctly");
    }

    function testShouldReturnSDaiPrice() external {
        // given
        address sDai = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        SDaiPriceFeed priceFeed = new SDaiPriceFeed();
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = sDai;
        sources[0] = address(priceFeed);

        vm.prank(OWNER);
        iporPriceOracleProxy.setAssetSources(assets, sources);

        // when
        uint256 result = iporPriceOracleProxy.getAssetPrice(sDai);

        // then
        assertEq(result, uint256(106851828), "Price should be calculated correctly");
    }
}
