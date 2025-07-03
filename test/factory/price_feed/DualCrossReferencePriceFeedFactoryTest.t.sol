// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DualCrossReferencePriceFeedFactory} from "../../../contracts/factory/price_feed/DualCrossReferencePriceFeedFactory.sol";
import {DualCrossReferencePriceFeed} from "../../../contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";

contract DualCrossReferencePriceFeedFactoryTest is Test {
    DualCrossReferencePriceFeedFactory public factory;
    address public constant WE_ETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address public constant WE_ETH_ETH_CHAINLINK_FEED = 0x5c9C449BbC9a6075A2c061dF312a35fd1E05fF22;
    address public constant ETH_USD_CHAINLINK_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant ADMIN = address(0x1);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_PROVIDER_URL"), 22773442);
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
        address priceFeed = factory.create(WE_ETH, WE_ETH_ETH_CHAINLINK_FEED, ETH_USD_CHAINLINK_FEED);

        // then
        assertTrue(priceFeed != address(0), "Price feed should be created");

        DualCrossReferencePriceFeed feed = DualCrossReferencePriceFeed(priceFeed);
        assertEq(feed.ASSET_X(), WE_ETH, "Asset X should be set correctly");
        assertEq(
            feed.ASSET_X_ASSET_Y_ORACLE_FEED(),
            WE_ETH_ETH_CHAINLINK_FEED,
            "Asset X/Asset Y feed should be set correctly"
        );
        assertEq(feed.ASSET_Y_USD_ORACLE_FEED(), ETH_USD_CHAINLINK_FEED, "Asset Y/USD feed should be set correctly");
    }

    function test_CreatePriceFeed_ZeroAddress() public {
        // when/then
        vm.expectRevert(DualCrossReferencePriceFeed.ZeroAddress.selector);
        factory.create(address(0), WE_ETH_ETH_CHAINLINK_FEED, ETH_USD_CHAINLINK_FEED);
    }

    function test_Upgrade_NotOwner() public {
        address caller = address(0x2);
        // given
        address newImplementation = address(new DualCrossReferencePriceFeedFactory());

        // when/then
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", caller));
        vm.startPrank(caller);
        factory.upgradeToAndCall(newImplementation, "");
        vm.stopPrank();
    }
}
