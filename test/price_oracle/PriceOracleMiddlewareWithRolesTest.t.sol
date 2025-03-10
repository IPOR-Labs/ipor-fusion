// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {SDaiPriceFeedEthereum} from "../../contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol";

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
    }

    function testShouldReturnDaiPrice() external {
        // given
        address dai = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(dai);

        // then
        assertEq(result, uint256(99984808 * 1e10), "Price should be calculated correctly");
    }

    function testShouldReturnUsdcPrice() external {
        // given
        address usdc = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(usdc);

        // then
        assertEq(result, uint256(99995746 * 1e10), "Price should be calculated correctly");
    }

    function testShouldReturnUsdtPrice() external {
        // given
        address usdt = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(usdt);

        // then
        assertEq(result, uint256(99975732 * 1e10), "Price should be calculated correctly");
    }

    function testShouldReturnEthPrice() external {
        // given
        address eth = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(eth);

        // then
        assertEq(result, uint256(334937530000 * 1e10), "Price should be calculated correctly");
    }

    function testShouldReturnSDaiPrice() external {
        // given
        address sDai = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
        SDaiPriceFeedEthereum priceFeed = new SDaiPriceFeedEthereum();
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = sDai;
        sources[0] = address(priceFeed);

        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.grantRole(priceOracleMiddlewareProxy.SET_ASSETS_PRICES_SOURCES(), ADMIN);

        priceOracleMiddlewareProxy.setAssetsPricesSources(assets, sources);
        vm.stopPrank();

        // when
        // solhint-disable-next-line no-unused-vars
        (uint256 result, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(sDai);

        // then
        assertEq(result, uint256(106851828 * 1e10), "Price should be calculated correctly");
    }
}
