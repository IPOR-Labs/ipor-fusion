// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {NapierHelper} from "../../fuses/napier/NapierHelper.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LogExpMath} from "@pendle/core-v2/contracts/core/libraries/math/LogExpMath.sol";
import {IPermit2} from "../../../contracts/fuses/balancer/ext/IPermit2.sol";

import {NapierPriceFeedFactory} from "../../../contracts/factory/price_feed/NapierPriceFeedFactory.sol";
import {NapierPtLpPriceFeed} from "../../../contracts/price_oracle/price_feed/NapierPtLpPriceFeed.sol";
import {ITokiChainlinkCompatOracle} from "../../../contracts/price_oracle/price_feed/ext/ITokiChainlinkCompatOracle.sol";
import {NapierYtLinearPriceFeed} from "../../../contracts/price_oracle/price_feed/NapierYtLinearPriceFeed.sol";
import {NapierYtTwapPriceFeed} from "../../../contracts/price_oracle/price_feed/NapierYtTwapPriceFeed.sol";
import {NapierConstants} from "../../fuses/napier/NapierConstants.sol";
import {Constants} from "../../../contracts/fuses/napier/utils/Constants.sol";
import {Actions} from "../../../contracts/fuses/napier/utils/Actions.sol";
import {Commands} from "../../../contracts/fuses/napier/utils/Commands.sol";
import {IV4Router} from "../../../contracts/fuses/napier/ext/IV4Router.sol";
import {IUniversalRouter} from "../../../contracts/fuses/napier/ext/IUniversalRouter.sol";
import {ITokiPoolToken} from "../../../contracts/fuses/napier/ext/ITokiPoolToken.sol";
import {IPrincipalToken} from "../../../contracts/fuses/napier/ext/IPrincipalToken.sol";

interface IChainlinkOracleFactory {
    function clone(
        address implementation,
        bytes calldata immutableData,
        bytes calldata initializationData
    ) external returns (address instance);
}

interface ITokiHook {
    function increaseObservationsCardinalityNext(PoolKey calldata key, uint16 cardinalityNext) external;
}

interface ITokiOracle {
    function checkTwapReadiness(
        address liquidityToken,
        uint32 twapWindow
    ) external view returns (bool needsCapacityIncrease, uint16 cardinalityRequired, bool hasOldestData);
}

contract NapierPriceFeedFactoryTest is Test {
    address private constant PRICE_MIDDLEWARE = 0xF9d7F359875E21b3A74BEd7Db40348f5393AF758;

    address private constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    ///  assets
    address private constant GAUNTLET_USDC_PRIME = 0x7c574174DA4b2be3f705c6244B4BfA0815a8B3Ed;
    address private constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    ///  Napier V2 Toki pool
    address private pool;
    address private principalToken;
    PoolKey private poolKey;

    ITokiChainlinkCompatOracle private linearOracle;
    ITokiChainlinkCompatOracle private twapOracle;

    // IPOR
    address private alice = makeAddr("alice");
    address private admin = makeAddr("admin");
    NapierPriceFeedFactory private implementation;
    NapierPriceFeedFactory private feedFactory;

    // config
    uint256 private constant DISCOUNT_RATE_YEARLY_BPS = 100; // 10%
    uint256 private constant TWAP_WINDOW = 1 hours;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_PROVIDER_URL"), 399992224);

        vm.label(PRICE_MIDDLEWARE, "priceMiddleware");
        vm.label(PERMIT2, "permit2");
        vm.label(GAUNTLET_USDC_PRIME, "gauntletUSDC");
        vm.label(USDC, "USDC");
        vm.label(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY, "tokiChainlinkFactory");
        vm.label(NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL, "linearPriceOracle");
        vm.label(NapierConstants.ARB_TOKI_TWAP_ORACLE_IMPL, "twapOracle");
        vm.label(NapierConstants.ARB_UNIVERSAL_ROUTER, "router");
        vm.label(NapierConstants.ARB_TOKI_ORACLE, "tokiOracle");
        vm.label(pool, "pool");

        (principalToken, pool) = _createNapierPool();
        poolKey = ITokiPoolToken(pool).i_poolKey();

        // Deploy implementation
        implementation = new NapierPriceFeedFactory();

        // Deploy feedFactory and initialize
        feedFactory = NapierPriceFeedFactory(
            address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", admin)))
        );
        vm.label(address(implementation), "implementation");
        vm.label(address(feedFactory), "feedFactory");

        (bool needsCapacityIncrease, uint16 cardinalityRequired, bool hasOldestData) = ITokiOracle(
            NapierConstants.ARB_TOKI_ORACLE
        ).checkTwapReadiness(pool, uint32(TWAP_WINDOW));

        // Increase cardinality slots if needed, then populate with historical data for TWAP oracle before oracle instance deployment
        if (needsCapacityIncrease) {
            ITokiHook(address(poolKey.hooks)).increaseObservationsCardinalityNext(poolKey, cardinalityRequired);
        }

        if (!hasOldestData) {
            uint256 amount0 = 10_000 * 10 ** ERC20(GAUNTLET_USDC_PRIME).decimals();
            deal(GAUNTLET_USDC_PRIME, alice, 2 * amount0);
            vm.startPrank(alice);
            ERC20(GAUNTLET_USDC_PRIME).approve(principalToken, type(uint256).max);
            uint256 amount1 = IPrincipalToken(principalToken).supply(amount0, alice);

            skip(TWAP_WINDOW / 5);
            _swap(poolKey, true, amount0 / 8);
            skip(TWAP_WINDOW / 5);
            _swap(poolKey, false, amount1 / 5);
            skip(TWAP_WINDOW / 3);
            _swap(poolKey, true, amount0 / 5);
            skip(TWAP_WINDOW / 2);
            _swap(poolKey, true, amount0 / 5);
            skip(TWAP_WINDOW / 10);
            _swap(poolKey, false, amount1 / 6);
            skip(TWAP_WINDOW / 2);
            _swap(poolKey, false, amount1 / 7);
            vm.stopPrank();
        }

        twapOracle = ITokiChainlinkCompatOracle(
            IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
                NapierConstants.ARB_TOKI_TWAP_ORACLE_IMPL,
                abi.encode(pool, principalToken, USDC, TWAP_WINDOW),
                ""
            )
        );
        linearOracle = ITokiChainlinkCompatOracle(
            IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
                NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL,
                abi.encode(pool, principalToken, USDC, DISCOUNT_RATE_YEARLY_BPS),
                ""
            )
        );
    }

    function _createNapierPool() internal returns (address pt, address tokipool) {
        uint256 scalarRoot = 16240223350842364143;
        int256 initialAnchor = 1098960161431879138;
        NapierHelper.FactorySuite memory suite = NapierHelper.FactorySuite({
            accessManagerImplementation: NapierConstants.ARB_ACCESS_MANAGER_IMPLEMENTATION,
            ptBlueprint: NapierConstants.ARB_PT_BLUEPRINT,
            resolverBlueprint: NapierConstants.ARB_ERC4626_RESOLVER_BLUEPRINT,
            poolDeployerImplementation: NapierConstants.ARB_TOKI_POOL_DEPLOYER_IMPLEMENTATION,
            poolArgs: abi.encode(
                NapierHelper.TokiPoolDeploymentParams({
                    salt: bytes32(0),
                    hook: NapierConstants.ARB_TOKI_HOOK,
                    pausableFlags: 0,
                    hookParams: NapierHelper.encodeHookParams(scalarRoot, initialAnchor),
                    hooklet: address(0),
                    hookletParams: "",
                    vault0: address(0),
                    vault1: address(0),
                    vault0Params: NapierHelper.DEFAULT_VAULT_PARAMS,
                    vault1Params: NapierHelper.DEFAULT_VAULT_PARAMS,
                    liquidityTokenImplementation: NapierConstants.ARB_LIQUIDITY_TOKEN_IMPLEMENTATION,
                    liquidityTokenImmutableData: ""
                })
            ),
            resolverArgs: abi.encode(GAUNTLET_USDC_PRIME)
        });

        uint128 ammFeeParams = uint128((uint256(LogExpMath.ln(1.01e18)) * Constants.TOKI_SWAP_FEE_SCALE) / 1e18);

        NapierHelper.FactoryModuleParam[] memory modules = new NapierHelper.FactoryModuleParam[](2);
        modules[0] = NapierHelper.FactoryModuleParam({
            moduleType: NapierHelper.ModuleIndex.FEE_MODULE_INDEX,
            implementation: NapierConstants.ARB_FEE_MODULE_IMPLEMENTATION,
            immutableData: abi.encode(
                NapierHelper.packFeePcts(NapierConstants.ARB_NAPIER_FACTORY, 10, 1000, 0, Constants.BASIS_POINTS)
            )
        });
        modules[1] = NapierHelper.FactoryModuleParam({
            moduleType: NapierHelper.ModuleIndex.POOL_FEE_MODULE_INDEX,
            implementation: NapierConstants.ARB_POOL_FEE_MODULE_IMPLEMENTATION,
            immutableData: abi.encode(
                NapierHelper.packFeePctsPool(NapierConstants.ARB_NAPIER_FACTORY, ammFeeParams, 200)
            )
        });

        vm.startPrank(admin);
        // Convert USDC to gauntletUSDC shares via ERC4626 deposit
        // Deposit enough USDC to get at least amount0 gauntletUSDC shares
        deal(USDC, admin, 100_000e6);
        ERC20(USDC).approve(GAUNTLET_USDC_PRIME, 100_000e6);
        uint256 amount0 = IERC4626(GAUNTLET_USDC_PRIME).deposit(100_000e6, admin);

        // Approve gauntletUSDC to Permit2
        ERC20(GAUNTLET_USDC_PRIME).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            GAUNTLET_USDC_PRIME,
            NapierConstants.ARB_UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );

        bytes32 salt = NapierHelper.minePrincipalTokenSalt(
            GAUNTLET_USDC_PRIME,
            NapierConstants.ARB_PT_BLUEPRINT,
            NapierConstants.ARB_NAPIER_FACTORY,
            admin,
            NapierConstants.ARB_UNIVERSAL_ROUTER
        );

        (pt, tokipool) = NapierHelper.deployTokiPoolAndAddLiquidity({
            router: NapierConstants.ARB_UNIVERSAL_ROUTER,
            suite: suite,
            modules: modules,
            expiry: block.timestamp + 365 days,
            curator: admin,
            salt: salt,
            amount0: amount0,
            receiver: admin,
            desiredImpliedRate: 0.05e18,
            liquidityMinimum: 0,
            deadline: block.timestamp + 1 hours
        });
        vm.stopPrank();
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        Currency currencyIn = zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = zeroForOne ? key.currency1 : key.currency0;

        ERC20(Currency.unwrap(currencyIn)).approve(PERMIT2, type(uint256).max);
        IPermit2(PERMIT2).approve(
            Currency.unwrap(currencyIn),
            NapierConstants.ARB_UNIVERSAL_ROUTER,
            type(uint160).max,
            type(uint48).max
        );

        bytes memory commands = abi.encodePacked(bytes1(uint8(Commands.V4_SWAP)));
        bytes memory v4Actions = abi.encodePacked(
            bytes1(uint8(Actions.SWAP_EXACT_IN_SINGLE)),
            bytes1(uint8(Actions.SETTLE)),
            bytes1(uint8(Actions.TAKE_ALL))
        );
        bytes[] memory v4Params = new bytes[](3);
        v4Params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: zeroForOne,
                amountIn: amountIn,
                amountOutMinimum: 0,
                hookData: ""
            })
        );
        v4Params[1] = abi.encode(currencyIn, amountIn, true); // payerIsUser=true to pull from user via permit2
        v4Params[2] = abi.encode(currencyOut, 0);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(v4Actions, v4Params);

        IUniversalRouter(NapierConstants.ARB_UNIVERSAL_ROUTER).execute(commands, inputs);
    }

    function testInitialize() public view {
        assertEq(feedFactory.owner(), admin, "Owner should be admin");
    }

    function testCannotReinitialize() public {
        // when & then
        vm.expectRevert();
        feedFactory.initialize(address(0x9999));
    }

    function testInitializeWithZeroAddress() public {
        // given
        NapierPriceFeedFactory newFactory = new NapierPriceFeedFactory();

        // when & then
        vm.expectRevert(abi.encodeWithSelector(NapierPriceFeedFactory.InvalidAddress.selector));
        new ERC1967Proxy(address(newFactory), abi.encodeWithSignature("initialize(address)", address(0)));
    }

    function testCreateLinearPriceFeed() public {
        // when
        vm.prank(admin);
        address priceFeedAddress = feedFactory.createPtLpPriceFeed(address(linearOracle));

        // then
        NapierPtLpPriceFeed priceFeed = NapierPtLpPriceFeed(priceFeedAddress);
        assertEq(address(priceFeed.TOKI_CHAINLINK_ORACLE()), address(linearOracle), "Toki oracle should match");
        assertEq(priceFeed.QUOTE(), USDC, "Quote asset should match");
        assertEq(priceFeed.BASE(), principalToken, "Base asset should match");
        assertEq(priceFeed.LIQUIDITY_TOKEN(), pool, "Liquidity token should match");
        assertEq(priceFeed.decimals(), 18, "Decimals should match");

        // Verify price feed is functional
        vm.prank(PRICE_MIDDLEWARE);
        (, int256 price, , uint256 timestamp, ) = priceFeed.latestRoundData();
        assertGt(price, 0, "Price should be positive");
        assertLt(price, 1e18, "Price should be less than 1e18");
        assertEq(timestamp, block.timestamp, "Timestamp should match block timestamp");

        console2.log("price", price);
    }

    function testCreateTwapPriceFeed() public {
        // when
        vm.prank(admin);
        address priceFeedAddress = feedFactory.createPtLpPriceFeed(address(twapOracle));

        // then
        NapierPtLpPriceFeed priceFeed = NapierPtLpPriceFeed(priceFeedAddress);
        assertEq(address(priceFeed.TOKI_CHAINLINK_ORACLE()), address(twapOracle), "Toki oracle should match");
        assertEq(priceFeed.QUOTE(), USDC, "Quote asset should match");
        assertEq(priceFeed.BASE(), principalToken, "Base asset should match");
        assertEq(priceFeed.LIQUIDITY_TOKEN(), pool, "Liquidity token should match");
        assertEq(priceFeed.decimals(), 18, "Decimals should match");

        // Verify price feed is functional
        vm.prank(PRICE_MIDDLEWARE);
        (, int256 price, , uint256 timestamp, ) = priceFeed.latestRoundData();
        assertGt(price, 0, "Price should be positive");
        assertLt(price, 1e18, "Price should be less than 1e18");
        assertEq(timestamp, block.timestamp, "Timestamp should match block timestamp");

        console2.log("price", price);
    }

    function testCreateYtTwapPriceFeed() public {
        vm.expectEmit(false, false, false, false, address(feedFactory));
        emit NapierPriceFeedFactory.NapierYtTwapPriceFeedCreated(
            address(0),
            NapierConstants.ARB_TOKI_ORACLE,
            pool,
            USDC,
            uint32(TWAP_WINDOW)
        );

        address priceFeedAddress = feedFactory.createYtTwapPriceFeed(
            NapierConstants.ARB_TOKI_ORACLE,
            pool,
            uint32(TWAP_WINDOW),
            USDC
        );

        NapierYtTwapPriceFeed ytFeed = NapierYtTwapPriceFeed(priceFeedAddress);
        assertEq(address(ytFeed.TOKI_ORACLE()), NapierConstants.ARB_TOKI_ORACLE, "toki oracle");
        assertEq(ytFeed.LIQUIDITY_TOKEN(), pool, "liquidity token");
        assertEq(ytFeed.QUOTE(), USDC, "quote");
        assertEq(ytFeed.UNDERLYING_TOKEN(), Currency.unwrap(poolKey.currency0), "underlying token");
        assertEq(ytFeed.TWAP_WINDOW(), uint32(TWAP_WINDOW), "twap window");
    }

    function testYtTwapPriceFeedPostExpiryReturnsMinimalPrice() public {
        address priceFeedAddress = feedFactory.createYtTwapPriceFeed(
            NapierConstants.ARB_TOKI_ORACLE,
            pool,
            uint32(TWAP_WINDOW),
            USDC
        );

        NapierYtTwapPriceFeed ytFeed = NapierYtTwapPriceFeed(priceFeedAddress);
        uint256 maturity = IPrincipalToken(principalToken).maturity();

        vm.warp(maturity + 1);

        vm.prank(PRICE_MIDDLEWARE);
        (, int256 price, , uint256 timestamp, ) = ytFeed.latestRoundData();

        assertEq(price, 1, "price should be minimal non-zero after maturity");
        assertEq(timestamp, block.timestamp, "timestamp should match");
    }

    function testCreateYtLinearPriceFeed() public {
        NapierYtLinearPriceFeed ytFeed = new NapierYtLinearPriceFeed(address(linearOracle));

        assertEq(address(ytFeed.TOKI_CHAINLINK_ORACLE()), address(linearOracle), "toki oracle");
        assertEq(ytFeed.LIQUIDITY_TOKEN(), pool, "liquidity token");
        assertEq(ytFeed.QUOTE(), USDC, "quote");
        assertEq(ytFeed.BASE(), IPrincipalToken(principalToken).i_yt(), "base should be YT");

        vm.prank(PRICE_MIDDLEWARE);
        (, int256 price, , uint256 timestamp, ) = ytFeed.latestRoundData();
        assertGt(price, 0, "price should be positive");
        assertEq(timestamp, block.timestamp, "timestamp should match");
    }

    function testYtLinearPriceFeedPostExpiryReturnsMinimalPrice() public {
        NapierYtLinearPriceFeed ytFeed = new NapierYtLinearPriceFeed(address(linearOracle));
        uint256 maturity = IPrincipalToken(principalToken).maturity();

        vm.warp(maturity + 1);

        vm.prank(PRICE_MIDDLEWARE);
        (, int256 price, , uint256 timestamp, ) = ytFeed.latestRoundData();

        assertEq(price, 1, "price should be minimal non-zero after maturity");
        assertEq(timestamp, block.timestamp, "timestamp should match");
    }

    function testRevertWhenCreateYtTwapPriceFeedWithZeroAddresses() public {
        vm.prank(admin);
        vm.expectRevert(NapierPriceFeedFactory.InvalidAddress.selector);
        feedFactory.createYtTwapPriceFeed(address(0), pool, uint32(TWAP_WINDOW), USDC);

        vm.prank(admin);
        vm.expectRevert(NapierPriceFeedFactory.InvalidAddress.selector);
        feedFactory.createYtTwapPriceFeed(NapierConstants.ARB_TOKI_ORACLE, address(0), uint32(TWAP_WINDOW), USDC);
    }

    function testRevertWhenCreateYtTwapPriceFeedWithShortTwapWindow() public {
        uint32 shortWindow = 1 minutes; // below MIN_TWAP_WINDOW

        vm.prank(admin);
        vm.expectRevert(NapierYtTwapPriceFeed.PriceOracleInvalidTwapWindow.selector);
        feedFactory.createYtTwapPriceFeed(NapierConstants.ARB_TOKI_ORACLE, pool, shortWindow, USDC);
    }

    function testRevertWhenCreateYtPriceFeedWithInvalidQuoteAsset() public {
        address badQuote = makeAddr("badQuote");

        vm.prank(admin);
        vm.expectRevert(NapierYtTwapPriceFeed.PriceOracleInvalidQuoteAsset.selector);
        feedFactory.createYtTwapPriceFeed(NapierConstants.ARB_TOKI_ORACLE, pool, uint32(TWAP_WINDOW), badQuote);
    }

    function testRevertWhenCreateYtLinearPriceFeedWithInvalidQuoteAsset() public {
        address badLinearOracle = IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
            NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL,
            abi.encode(pool, principalToken, USDC, DISCOUNT_RATE_YEARLY_BPS),
            ""
        );
        bytes memory badImmutableArgs = abi.encode(pool, principalToken, GAUNTLET_USDC_PRIME, 0);
        vm.mockCall(
            badLinearOracle,
            abi.encodeWithSelector(ITokiChainlinkCompatOracle.parseImmutableArgs.selector),
            badImmutableArgs
        );

        vm.expectRevert(NapierYtLinearPriceFeed.PriceOracleInvalidQuoteAsset.selector);
        new NapierYtLinearPriceFeed(badLinearOracle);
    }

    function testRevertWhenCreateYtLinearPriceFeedWithNonPrincipalBase() public {
        address badLinearOracle = IChainlinkOracleFactory(NapierConstants.ARB_CHAINLINK_COMPT_ORACLE_FACTORY).clone(
            NapierConstants.ARB_TOKI_LINEAR_PRICE_ORACLE_IMPL,
            abi.encode(pool, principalToken, USDC, TWAP_WINDOW),
            ""
        );
        bytes memory badImmutableArgs = abi.encode(pool, pool, GAUNTLET_USDC_PRIME, 0);
        vm.mockCall(
            badLinearOracle,
            abi.encodeWithSelector(ITokiChainlinkCompatOracle.parseImmutableArgs.selector),
            badImmutableArgs
        );

        vm.expectRevert(NapierYtLinearPriceFeed.PriceOracleInvalidBaseAsset.selector);
        new NapierYtLinearPriceFeed(badLinearOracle);
    }

    function testRevertWhenCreateWithInvalidPtLpOracleAddress() public {
        // when & then
        vm.expectRevert(abi.encodeWithSelector(NapierPriceFeedFactory.InvalidAddress.selector));
        vm.prank(admin);
        feedFactory.createPtLpPriceFeed(address(0));
    }

    function testRevertWhenCreateWithInvalidYtLinearOracleAddress() public {
        // when & then
        vm.expectRevert(abi.encodeWithSelector(NapierPriceFeedFactory.InvalidAddress.selector));
        vm.prank(admin);
        feedFactory.createYtLinearPriceFeed(address(0));
    }

    function testOwnershipTransfer() public {
        // given
        assertEq(feedFactory.owner(), admin, "Initial owner should be admin");
        address newOwner = makeAddr("newOwner");

        // when - start transfer
        vm.prank(admin);
        feedFactory.transferOwnership(newOwner);

        // then - ownership not yet transferred
        assertEq(feedFactory.owner(), admin, "Owner should still be admin");
        assertEq(feedFactory.pendingOwner(), newOwner, "Pending owner should be newOwner");

        // when - accept transfer
        vm.prank(newOwner);
        feedFactory.acceptOwnership();

        // then - ownership transferred
        assertEq(feedFactory.owner(), newOwner, "Owner should now be newOwner");
    }

    function testUpgradeAsOwner() public {
        // given
        NapierPriceFeedFactory newImplementation = new NapierPriceFeedFactory();

        // when
        vm.prank(admin);
        feedFactory.upgradeToAndCall(address(newImplementation), "");

        // then - feedFactory still works and owner is preserved
        assertEq(feedFactory.owner(), admin, "Owner should still be admin after upgrade");
    }

    function testUpgradeAsNonOwnerReverts() public {
        // given
        NapierPriceFeedFactory newImplementation = new NapierPriceFeedFactory();

        // when & then
        vm.expectRevert();
        vm.prank(address(0x9999));
        feedFactory.upgradeToAndCall(address(newImplementation), "");
    }
}
