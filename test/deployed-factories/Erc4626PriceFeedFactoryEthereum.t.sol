// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IPriceFeed} from "../../contracts/price_oracle/price_feed/IPriceFeed.sol";
import {IPriceOracleMiddleware} from "../../contracts/price_oracle/IPriceOracleMiddleware.sol";

/// @dev Minimal interface transcribed from the verified ABI of implementation
/// 0xe08AfF4910Fb61AcC2EacB03b0a6132B01D1aa61.
interface IDeployedErc4626PriceFeedFactory {
    function create(address vaultAddress_, address priceOracleMiddleware_) external returns (address priceFeedAddress);
}

interface IErc4626PriceFeed {
    function vault() external view returns (address);
}

/// @notice Compatibility test for the deployed ERC4626 price feed factory.
/// @dev Fixture type: deployed-usage. The factory, the middleware and the ERC4626
/// vault are used unchanged: no upgrade, no etch, no role granted, no funding.
/// The only state it creates is the price feed the factory itself deploys, and it
/// exists only on the ephemeral fork.
contract Erc4626PriceFeedFactoryEthereumTest is Test {
    address private constant FEED_FACTORY = 0xf58Fcce9370aBa552032d3EA47baA486F70c0FdC;
    address private constant PRICE_ORACLE_MIDDLEWARE = 0xC9F32d65a278b012371858fD3cdE315B12d664c6;
    address private constant STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    address private constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    uint256 private constant FORK_BLOCK = 25937526;

    address private caller;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), vm.envOr("FUSION_FORK_BLOCK", FORK_BLOCK));
        caller = makeAddr("priceFeedCaller");
    }

    function testShouldCreateAWorkingFeedThroughTheDeployedFactory() public {
        assertEq(block.chainid, 1, "wrong chain");
        assertTrue(FEED_FACTORY.code.length > 0, "feed factory has no code");

        vm.prank(caller);
        address feed = IDeployedErc4626PriceFeedFactory(FEED_FACTORY).create(
            STEAKHOUSE_USDC,
            PRICE_ORACLE_MIDDLEWARE
        );

        assertTrue(feed != address(0), "factory returned the zero address");
        assertTrue(feed.code.length > 0, "created feed has no code");
        assertEq(IErc4626PriceFeed(feed).vault(), STEAKHOUSE_USDC, "feed points at another vault");
        assertEq(IPriceFeed(feed).decimals(), 18, "feed does not report WAD decimals");

        // The feed asks its caller for the asset price, so only the middleware can
        // read it. This is a static call to contracts that are used unchanged.
        vm.prank(PRICE_ORACLE_MIDDLEWARE);
        (, int256 price, , , ) = IPriceFeed(feed).latestRoundData();
        assertGt(price, 0, "feed returned a non-positive price");

        // Independently recomputed from the same sources, in the same unit.
        (uint256 assetPrice, uint256 assetPriceDecimals) = IPriceOracleMiddleware(PRICE_ORACLE_MIDDLEWARE)
            .getAssetPrice(USDC);
        uint256 sharePriceInAssets = IERC4626(STEAKHOUSE_USDC).convertToAssets(
            10 ** IERC4626(STEAKHOUSE_USDC).decimals()
        );
        uint256 expected = (sharePriceInAssets * assetPrice * 1e18) /
            10 ** (IERC20Metadata(USDC).decimals() + assetPriceDecimals);
        assertApproxEqAbs(uint256(price), expected, 1, "feed price does not match the recomputed value");

        // A share of a USDC vault is worth about a dollar, in WAD.
        assertGt(uint256(price), 0.5e18, "price is implausibly low for a USDC vault share");
        assertLt(uint256(price), 5e18, "price is implausibly high for a USDC vault share");
    }

    function testShouldRejectAVaultThatIsNotErc4626() public {
        vm.prank(caller);
        vm.expectRevert();
        IDeployedErc4626PriceFeedFactory(FEED_FACTORY).create(USDC, PRICE_ORACLE_MIDDLEWARE);
    }
}
