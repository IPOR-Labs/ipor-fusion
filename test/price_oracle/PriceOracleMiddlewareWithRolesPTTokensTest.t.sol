// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {SDaiPriceFeedEthereum} from "../../contracts/price_oracle/price_feed/chains/ethereum/SDaiPriceFeedEthereum.sol";

contract PriceOracleMiddlewareWithRolesPTTokensTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address public constant BASE_CURRENCY = 0x0000000000000000000000000000000000000348;
    uint256 public constant BASE_CURRENCY_DECIMALS = 8;
    address public constant ADMIN = 0xD92E9F039E4189c342b4067CC61f5d063960D248;

    PriceOracleMiddlewareWithRoles private priceOracleMiddlewareProxy;

    address private constant PT_SUSDE = 0xb7de5dFCb74d25c2f21841fbd6230355C50d9308;
    // address private constant MARCKET_SUSDE = 0xB162B764044697cf03617C2EFbcB1f42e31E4766;
    address private constant MARCKET_SUSDE = 0xF4Cf59259D007a96C641B41621aB52C93b9691B1;
    address public constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address public constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22026402);
        PriceOracleMiddlewareWithRoles implementation = new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY);

        priceOracleMiddlewareProxy = PriceOracleMiddlewareWithRoles(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", ADMIN)))
        );

        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.grantRole(priceOracleMiddlewareProxy.ADD_PT_TOKEN_PRICE(), ADMIN);
        vm.stopPrank();
    }

    function testTest() public {
        vm.startPrank(ADMIN);
        priceOracleMiddlewareProxy.addNewPtToken(PENDLE_ORACLE, MARCKET_SUSDE, uint32(300), 1e18);
        vm.stopPrank();

        (uint256 assetPrice, uint256 decimals) = priceOracleMiddlewareProxy.getAssetPrice(SUSDE);
        console2.log("assetPrice", assetPrice);
        console2.log("decimals", decimals);
    }
}
// 0,8415 100/118,808= buy pt
// 0,840972 sell pt
// 0,841101214743130988 price pt
