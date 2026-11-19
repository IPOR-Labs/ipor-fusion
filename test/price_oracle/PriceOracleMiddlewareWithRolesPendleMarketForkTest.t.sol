// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IStandardizedYield} from "@pendle/core-v2/contracts/interfaces/IStandardizedYield.sol";
import {IPPrincipalToken} from "@pendle/core-v2/contracts/interfaces/IPPrincipalToken.sol";
import {IPMarket} from "@pendle/core-v2/contracts/interfaces/IPMarket.sol";
import {IPYieldToken} from "@pendle/core-v2/contracts/interfaces/IPYieldToken.sol";
import {IPPYLpOracle} from "@pendle/core-v2/contracts/interfaces/IPPYLpOracle.sol";
import {PriceOracleMiddlewareWithRoles} from "../../contracts/price_oracle/PriceOracleMiddlewareWithRoles.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";
import {PtPriceFeed} from "../../contracts/price_oracle/price_feed/PtPriceFeed.sol";

/// @dev Market lookalike: own readTokens (PT = arbitrary token) and a configurable factory()
contract FakePendleMarket {
    address public factory;
    address public sy;
    address public pt;
    address public yt;

    constructor(address factory_, address sy_, address pt_) {
        factory = factory_;
        sy = sy_;
        pt = pt_;
        yt = address(new FakePendleYt());
    }

    function readTokens() external view returns (IStandardizedYield, IPPrincipalToken, IPYieldToken) {
        return (IStandardizedYield(sy), IPPrincipalToken(pt), IPYieldToken(yt));
    }

    /// @dev Already expired, so the Pendle oracle library prices the PT 1:1 and needs no observations
    function expiry() external pure returns (uint256) {
        return 0;
    }
}

/// @dev YT lookalike with the index getters read by PendlePYOracleLib
contract FakePendleYt {
    function pyIndexStored() external pure returns (uint256) {
        return 1e18;
    }

    function doCacheIndexSameBlock() external pure returns (bool) {
        return false;
    }

    function pyIndexLastUpdatedBlock() external pure returns (uint128) {
        return 0;
    }
}

/// @dev Factory lookalike that approves every market
contract AcceptAllPendleFactory {
    function isValidMarket(address) external pure returns (bool) {
        return true;
    }
}

/// @dev PT lookalike reporting a configurable SY
contract FakePendlePt {
    address public SY;

    constructor(address sy_) {
        SY = sy_;
    }
}

/// @title Fork test of the Pendle market validation in PriceOracleMiddlewareWithRoles (IL-9660)
contract PriceOracleMiddlewareWithRolesPendleMarketForkTest is Test {
    address private constant CHAINLINK_FEED_REGISTRY = 0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf;
    address private constant PENDLE_ORACLE = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address private constant PENDLE_MARKET_FACTORY_V3 = 0x6fcf753f2C67b83f7B09746Bbc4FA0047b35D050;
    address private constant ADMIN = 0xD92E9F039E4189c342b4067CC61f5d063960D248;
    address private constant MARKET_USDE = 0xB451A36c8B6b2EAc77AD0737BA732818143A0E25;
    address private constant SY_USDE = 0x4dB99b79361F98865230f5702de024C69f629fEC;
    address private constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    uint32 private constant TWAP = 300;
    int256 private constant USDE_PT_PRICE = 99503847;

    /// @dev ERC-7201: keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.PendleMarketFactories")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant FACTORIES_SLOT = 0x53d4a51401004c714bc12df9f19e6f479acc264fd594e584ce5de34f8e34a300;

    /// @dev Mirror of PriceOracleMiddlewareStorageLib.PendleMarketFactoryUpdated, declared here so the file also compiles on the audited base
    event PendleMarketFactoryUpdated(address factory, bool allowed);

    PriceOracleMiddlewareWithRoles private middleware;
    address private _implementation;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22061720);
        _implementation = address(new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY));
        middleware = PriceOracleMiddlewareWithRoles(
            address(new ERC1967Proxy(_implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
        vm.startPrank(ADMIN);
        middleware.grantRole(middleware.ADD_PT_TOKEN_PRICE(), ADMIN);
        middleware.grantRole(middleware.SET_ASSETS_PRICES_SOURCES(), ADMIN);
        vm.stopPrank();
    }

    function testShouldCreateFeedForRealMarketOfRegisteredFactory() public {
        _registerFactory(PENDLE_MARKET_FACTORY_V3);

        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, MARKET_USDE, TWAP, USDE_PT_PRICE, 1);

        (, IPPrincipalToken pt, ) = IPMarket(MARKET_USDE).readTokens();
        assertTrue(middleware.getSourceOfAssetPrice(address(pt)) != address(0), "feed registered");
    }

    /// @dev Regression: on the audited base the lookalike market is accepted and WETH gets a PT feed as its price source
    function testShouldRevertForLookalikeMarketThatClaimsTheRealFactory() public {
        // given - the registered real factory does not know the lookalike market
        _registerFactoryIfSupported(PENDLE_MARKET_FACTORY_V3);
        FakePendleMarket fake = new FakePendleMarket(PENDLE_MARKET_FACTORY_V3, SY_USDE, WETH);
        int256 price = _prepareFeedConstruction(address(fake));

        // when & then
        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", fake));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, address(fake), TWAP, price, 1);

        assertEq(middleware.getSourceOfAssetPrice(WETH), address(0), "WETH source untouched");
    }

    function testShouldRevertForLookalikeMarketOfUnregisteredFactory() public {
        // given - the lookalike brings its own factory that approves everything
        _registerFactoryIfSupported(PENDLE_MARKET_FACTORY_V3);
        address attackerFactory = address(new AcceptAllPendleFactory());
        FakePendleMarket fake = new FakePendleMarket(attackerFactory, SY_USDE, WETH);
        int256 price = _prepareFeedConstruction(address(fake));

        // when & then
        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", fake));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, address(fake), TWAP, price, 1);
    }

    function testShouldRevertWhenSetOfFactoriesIsEmpty() public {
        // given - nothing registered (state right after an upgrade)
        assertEq(_factories().length, 0, "set empty");

        // when & then - even a genuine market is refused
        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", MARKET_USDE));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, MARKET_USDE, TWAP, USDE_PT_PRICE, 1);
    }

    function testShouldRevertAfterFactoryIsRemoved() public {
        _registerFactory(PENDLE_MARKET_FACTORY_V3);
        address[] memory factories = new address[](1);
        factories[0] = PENDLE_MARKET_FACTORY_V3;
        vm.prank(ADMIN);
        _setFactories(factories, false);

        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", MARKET_USDE));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, MARKET_USDE, TWAP, USDE_PT_PRICE, 1);
    }

    function testShouldRevertWhenMarketDoesNotExposeFactory() public {
        _registerFactory(PENDLE_MARKET_FACTORY_V3);
        address eoa = makeAddr("notAMarket");

        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", eoa));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, eoa, TWAP, 1e8, 1);
    }

    function testShouldRevertWhenPtDoesNotBelongToSy() public {
        // given - a (mistakenly) trusted factory that approves the market, but PT.SY() differs from the market SY
        address acceptAll = address(new AcceptAllPendleFactory());
        _registerFactory(acceptAll);
        FakePendlePt pt = new FakePendlePt(makeAddr("otherSy"));
        FakePendleMarket fake = new FakePendleMarket(acceptAll, SY_USDE, address(pt));
        int256 price = _prepareFeedConstruction(address(fake));

        // when & then
        vm.expectRevert(abi.encodeWithSignature("InvalidPendleMarket(address)", fake));
        vm.prank(ADMIN);
        middleware.createAndAddPtTokenPriceFeed(PENDLE_ORACLE, address(fake), TWAP, price, 1);
    }

    function testShouldRestrictSettingFactoriesToSetAssetsPricesSourcesRole() public {
        address[] memory factories = new address[](1);
        factories[0] = PENDLE_MARKET_FACTORY_V3;
        address stranger = makeAddr("stranger");
        bytes32 role = middleware.SET_ASSETS_PRICES_SOURCES();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        vm.prank(stranger);
        _setFactories(factories, true);
    }

    function testShouldRejectZeroFactoryAndEmptyArray() public {
        address[] memory zero = new address[](1);
        vm.expectRevert(abi.encodeWithSignature("PendleMarketFactoryCanNotBeZero()"));
        vm.prank(ADMIN);
        _setFactories(zero, true);

        vm.expectRevert(IPriceOracleMiddleware.EmptyArrayNotSupported.selector);
        vm.prank(ADMIN);
        _setFactories(new address[](0), true);
    }

    function testShouldEmitEventAndExposeFactories() public {
        address[] memory factories = new address[](1);
        factories[0] = PENDLE_MARKET_FACTORY_V3;

        vm.expectEmit(true, true, true, true);
        emit PendleMarketFactoryUpdated(PENDLE_MARKET_FACTORY_V3, true);
        vm.prank(ADMIN);
        _setFactories(factories, true);

        assertEq(_factories().length, 1, "one factory");
        assertEq(_factories()[0], PENDLE_MARKET_FACTORY_V3, "factory listed");
    }

    /// @dev Storage layout proof: the set lives only in its ERC-7201 slot, which does not collide with the price
    /// sources or the access control state, and existing sources and roles survive an upgrade
    function testShouldKeepStorageIntactAcrossUpgradeAndUseOnlyNamespacedSlot() public {
        // given - state written by the "old" implementation
        address[] memory assets = new address[](1);
        assets[0] = WETH;
        address[] memory sources = new address[](1);
        sources[0] = makeAddr("wethFeed");
        vm.prank(ADMIN);
        middleware.setAssetsPricesSources(assets, sources);

        bytes32 sourcesSlot = 0xefe839ce0caa5648581e30daa19dcc84419e945902cc17f7f481f056193edd00;
        assertTrue(FACTORIES_SLOT != sourcesSlot, "distinct namespaces");
        assertEq(
            FACTORIES_SLOT,
            keccak256(abi.encode(uint256(keccak256("io.ipor.priceOracle.PendleMarketFactories")) - 1)) &
                ~bytes32(uint256(0xff)),
            "ERC-7201 derivation"
        );
        assertEq(uint256(vm.load(address(middleware), FACTORIES_SLOT)), 0, "namespace empty before");

        // when - upgrade to a fresh implementation and register a factory
        address newImplementation = address(new PriceOracleMiddlewareWithRoles(CHAINLINK_FEED_REGISTRY));
        vm.prank(ADMIN);
        middleware.upgradeToAndCall(newImplementation, "");
        _registerFactory(PENDLE_MARKET_FACTORY_V3);

        // then - only the namespaced slot changed in the factory area, old state is intact
        assertEq(uint256(vm.load(address(middleware), FACTORIES_SLOT)), 1, "values array length in own slot");
        assertEq(middleware.getSourceOfAssetPrice(WETH), sources[0], "price source preserved");
        assertTrue(middleware.hasRole(middleware.ADD_PT_TOKEN_PRICE(), ADMIN), "roles preserved");
        assertEq(uint256(vm.load(address(middleware), sourcesSlot)), 0, "sources mapping base slot untouched");
    }

    function _registerFactory(address factory_) private {
        address[] memory factories = new address[](1);
        factories[0] = factory_;
        vm.prank(ADMIN);
        _setFactories(factories, true);
    }

    /// @dev Registers the factory when the function exists; the audited base has no such function, so the call is ignored there
    function _registerFactoryIfSupported(address factory_) private {
        address[] memory factories = new address[](1);
        factories[0] = factory_;
        vm.prank(ADMIN);
        address(middleware).call(abi.encodeWithSignature("setPendleMarketFactories(address[],bool)", factories, true));
    }

    /// @dev Calls setPendleMarketFactories as the current prank and bubbles up its revert data
    function _setFactories(address[] memory factories_, bool allowed_) private {
        (bool ok, bytes memory data) = address(middleware).call(
            abi.encodeWithSignature("setPendleMarketFactories(address[],bool)", factories_, allowed_)
        );
        if (!ok) {
            assembly {
                revert(add(data, 0x20), mload(data))
            }
        }
    }

    function _factories() private view returns (address[] memory) {
        (bool ok, bytes memory data) = address(middleware).staticcall(
            abi.encodeWithSignature("getPendleMarketFactories()")
        );
        require(ok, "getPendleMarketFactories failed");
        return abi.decode(data, (address[]));
    }

    /// @dev Lets PtPriceFeed construction succeed for a lookalike market (the Pendle oracle state is mocked), so that the
    /// only thing standing between it and the price source registry is the market validation. Returns the feed price
    /// of the lookalike market, to be used as the expected price.
    function _prepareFeedConstruction(address market_) private returns (int256 price) {
        vm.mockCall(
            PENDLE_ORACLE,
            abi.encodeWithSelector(IPPYLpOracle.getOracleState.selector, market_, TWAP),
            abi.encode(false, uint16(0), true)
        );
        PtPriceFeed probe = new PtPriceFeed(PENDLE_ORACLE, market_, TWAP, address(middleware), 1);
        (, price, , , ) = probe.latestRoundData();
    }
}
