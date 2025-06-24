// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DualCrossReferencePriceFeedFactory} from "../../../contracts/factory/price_feed/DualCrossReferencePriceFeedFactory.sol";
import {DualCrossReferencePriceFeed} from "../../../contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";


contract DualCrossReferencePriceFeedFactoryTest is Test {
    DualCrossReferencePriceFeedFactory public factory;
    address public constant WST_ETH = 0x5979D7b546E38E414F7E9822514be443A4800529;
    address public constant WST_ETH_ETH_CHAINLINK_FEED = 0xb523AE262D20A936BC152e6023996e46FDC2A95D;
    address public constant ETH_USD_CHAINLINK_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address public constant ADMIN = address(0x1);

    function setUp() public {
        // Deploy implementation
        address implementation = address(new DualCrossReferencePriceFeedFactory());

        // Deploy and initialize proxy
        factory = DualCrossReferencePriceFeedFactory(
            address(new ERC1967Proxy(implementation, abi.encodeWithSignature("initialize(address)", ADMIN)))
        );
    }

    function test_Initialize() public {
        assertEq(factory.owner(), ADMIN, "Owner should be set correctly");
    }

    function test_CreatePriceFeed() public {
        // when
        address priceFeed = factory.create(WST_ETH, WST_ETH_ETH_CHAINLINK_FEED, ETH_USD_CHAINLINK_FEED);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        DualCrossReferencePriceFeed feed = DualCrossReferencePriceFeed(priceFeed);
        assertEq(feed.ASSET_X(), WST_ETH, "Asset X should be set correctly");
        assertEq(
            feed.ASSET_X_ASSET_Y_ORACLE_FEED(),
            WST_ETH_ETH_CHAINLINK_FEED,
            "Asset X/Asset Y feed should be set correctly"
        );
        assertEq(feed.ASSET_Y_USD_ORACLE_FEED(), ETH_USD_CHAINLINK_FEED, "Asset Y/USD feed should be set correctly");
    }

    function test_CreatePriceFeed_ZeroAddress() public {
        // when/then
        vm.expectRevert(DualCrossReferencePriceFeed.ZeroAddress.selector);
        factory.create(address(0), WST_ETH_ETH_CHAINLINK_FEED, ETH_USD_CHAINLINK_FEED);
    }

    function test_CreatePriceFeed_Event() public {
        // when
        vm.expectEmit(true, true, true, true);
        emit DualCrossReferencePriceFeedFactory.DualCrossReferencePriceFeedCreated(
            address(0), // We don't know the exact address, so we use address(0)
            WST_ETH,
            WST_ETH_ETH_CHAINLINK_FEED,
            ETH_USD_CHAINLINK_FEED
        );

        factory.create(WST_ETH, WST_ETH_ETH_CHAINLINK_FEED, ETH_USD_CHAINLINK_FEED);
    }

    function test_Upgrade() public {
        // given
        address newImplementation = address(new DualCrossReferencePriceFeedFactory());

        // when
        vm.prank(ADMIN);
        factory.upgradeToAndCall(newImplementation, "");

        // then
        assertEq(factory.implementation(), newImplementation, "Implementation should be upgraded");
    }

    function test_Upgrade_NotOwner() public {
        // given
        address newImplementation = address(new DualCrossReferencePriceFeedFactory());

        // when/then
        vm.expectRevert("Ownable: caller is not the owner");
        factory.upgradeToAndCall(newImplementation, "");
    }
}
