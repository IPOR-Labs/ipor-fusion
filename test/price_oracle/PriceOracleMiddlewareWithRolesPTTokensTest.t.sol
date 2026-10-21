// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {SDaiPriceFeedEthereum} from "../../contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol";
import {PendleOracleMethodLib} from "../../contracts/price_oracle/price_feed/lib/PendleOracleMethodLib.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";

struct TestItem {
    address market;
    int256 price;
    uint256 usePendleOracleMethod;
    uint256 blockNumber;
}
contract PriceOracleMiddlewareWithRolesPTTokensTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant ADMIN = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddlewareWithRoles private priceOracleMiddlewareProxy;

    address private constant PT_SUSDE = 0xb7de5dFCb74d25c2f21841fbd6230355C50d9308;
    address private constant MARCKET_SUSDE = 0xF4Cf59259D007a96C641B41621aB52C93b9691B1;
    address public constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    address private constant MARKET_SUSDE_MAY_2025 = 0xB162B764044697cf03617C2EFbcB1f42e31E4766;
    address private constant SY_SUSDE = 0xE877B2A8a53763C8B0534a15e87da28f3aC1257e;
    address private constant MARKET_USDE = 0xB451A36c8B6b2EAc77AD0737BA732818143A0E25;
    address private constant SY_USDE = 0x4dB99b79361F98865230f5702de024C69f629fEC;
    /// @dev Mirrors PendleOracleMethodLib.MAX_SY_EXCHANGE_RATE_DEVIATION (0.01%)
    uint256 private constant MAX_SY_EXCHANGE_RATE_DEVIATION = 1e14;

    TestItem private _activeItem;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22061720);
        PriceOracleMiddlewareWithRoles implementation = new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY);

        priceOracleMiddlewareProxy = PriceOracleMiddlewareWithRoles(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.grantRole(priceOracleMiddlewareProxy.ADD_PT_TOKEN_PRICE(), ADMIN);
        vm.stopPrank();
    }
    function testShouldCreateAndAddPtTokenPriceFeed() public activeItem {
        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            _activeItem.market,
            uint32(300),
            _activeItem.price,
            _activeItem.usePendleOracleMethod
        );
        vm.stopPrank();
    }

    function testShouldRevertWhenPendleOracleMethodIsUnknown() public {
        // given
        uint256 unknownMethod = 2;

        // when & then
        vm.expectRevert(
            abi.encodeWithSelector(PendleOracleMethodLib.InvalidPendleOracleMethod.selector, unknownMethod)
        );
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            MARKET_USDE,
            uint32(300),
            int256(99503847),
            unknownMethod
        );
    }

    function testShouldRevertWhenPtToSyMethodUsedWithSyNotOneToOne() public {
        // given - SY-sUSDe exchange rate to USDe is ~1.1628 at this block; method 0 would price PT-sUSDe
        // at ~$0.841 instead of ~$0.980, and the expected price computed the same way would pass the 1% check
        uint256 syExchangeRate = IStandardizedYield(SY_SUSDE).exchangeRate();

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PendleOracleMethodLib.SyExchangeRateNotOne.selector, syExchangeRate));
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            MARKET_SUSDE_MAY_2025,
            uint32(300),
            int256(84102754),
            PendleOracleMethodLib.PT_TO_SY
        );
    }

    function testShouldAcceptPtToSyMethodWhenSyExchangeRateAtMaxDeviation() public {
        // given
        vm.mockCall(
            SY_USDE,
            abi.encodeWithSelector(IStandardizedYield.exchangeRate.selector),
            abi.encode(1e18 + MAX_SY_EXCHANGE_RATE_DEVIATION)
        );

        // when
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            MARKET_USDE,
            uint32(300),
            int256(99503847),
            PendleOracleMethodLib.PT_TO_SY
        );

        // then
        (, IPPrincipalToken pt, ) = IPMarket(MARKET_USDE).readTokens();
        assertTrue(priceOracleMiddlewareProxy.getSourceOfAssetPrice(address(pt)) != address(0), "PT price feed set");
    }

    function testShouldRevertPtToSyMethodWhenSyExchangeRateAboveMaxDeviation() public {
        // given
        uint256 syExchangeRate = 1e18 + MAX_SY_EXCHANGE_RATE_DEVIATION + 1;
        vm.mockCall(
            SY_USDE,
            abi.encodeWithSelector(IStandardizedYield.exchangeRate.selector),
            abi.encode(syExchangeRate)
        );

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PendleOracleMethodLib.SyExchangeRateNotOne.selector, syExchangeRate));
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            MARKET_USDE,
            uint32(300),
            int256(99503847),
            PendleOracleMethodLib.PT_TO_SY
        );
    }

    function testShouldRevertPtToSyMethodWhenSyExchangeRateBelowMaxDeviation() public {
        // given
        uint256 syExchangeRate = 1e18 - MAX_SY_EXCHANGE_RATE_DEVIATION - 1;
        vm.mockCall(
            SY_USDE,
            abi.encodeWithSelector(IStandardizedYield.exchangeRate.selector),
            abi.encode(syExchangeRate)
        );

        // when & then
        vm.expectRevert(abi.encodeWithSelector(PendleOracleMethodLib.SyExchangeRateNotOne.selector, syExchangeRate));
        vm.prank(ADMIN);
        priceOracleMiddlewareProxy.createAndAddPtTokenPriceFeed(
            PENDLE_ORACLE,
            MARKET_USDE,
            uint32(300),
            int256(99503847),
            PendleOracleMethodLib.PT_TO_SY
        );
    }

    function _getTestItems() private view returns (TestItem[] memory testItems) {
        testItems = new TestItem[](5);
        testItems[0] = TestItem({
            market: 0xB162B764044697cf03617C2EFbcB1f42e31E4766,
            price: int256(97987020),
            usePendleOracleMethod: 1,
            blockNumber: 0
        }); // MARCKET_SUSDE
        testItems[1] = TestItem({
            market: 0x85667e484a32d884010Cf16427D90049CCf46e97,
            price: int256(97221872),
            usePendleOracleMethod: 0,
            blockNumber: 0
        }); // https://app.pendle.finance/trade/markets/0x85667e484a32d884010cf16427d90049ccf46e97/swap?view=pt&chain=ethereum&tab=info
        testItems[2] = TestItem({
            market: 0xB451A36c8B6b2EAc77AD0737BA732818143A0E25,
            price: int256(99503847),
            usePendleOracleMethod: 0,
            blockNumber: 0
        }); // https://app.pendle.finance/trade/markets/0xb451a36c8b6b2eac77ad0737ba732818143a0e25/swap?view=pt&chain=ethereum&tab=info
        testItems[3] = TestItem({
            market: 0x353d0B2EFB5B3a7987fB06D30Ad6160522d08426,
            price: int256(99716640),
            usePendleOracleMethod: 1,
            blockNumber: 0
        }); // https://app.pendle.finance/trade/markets/0x353d0b2efb5b3a7987fb06d30ad6160522d08426/swap?view=pt&chain=ethereum
        testItems[4] = TestItem({
            market: 0xC374f7eC85F8C7DE3207a10bB1978bA104bdA3B2,
            price: int256(182040012762),
            usePendleOracleMethod: 1,
            blockNumber: 0
        }); // https://app.pendle.finance/trade/markets/0xc374f7ec85f8c7de3207a10bb1978ba104bda3b2/swap?view=pt&chain=ethereum&py=input
        return testItems;
    }

    modifier activeItem() {
        TestItem[] memory testItems = _getTestItems();
        for (uint256 i; i < testItems.length; i++) {
            _activeItem = testItems[i];
            _;
        }
    }
}
