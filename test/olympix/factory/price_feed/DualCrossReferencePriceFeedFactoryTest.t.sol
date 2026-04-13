// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {OlympixUnitTest} from "../../../../test/OlympixUnitTest.sol";
import {DualCrossReferencePriceFeedFactory} from "../../../../contracts/factory/price_feed/DualCrossReferencePriceFeedFactory.sol";

import {DualCrossReferencePriceFeed} from "contracts/price_oracle/price_feed/DualCrossReferencePriceFeed.sol";
import {Ownable2StepUpgradeable} from "node_modules/@chainlink/contracts/node_modules/@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
contract DualCrossReferencePriceFeedFactoryTest is OlympixUnitTest("DualCrossReferencePriceFeedFactory") {

    function setUp() public override {
        // Setup will be filled by Olympix
    }

    function test_initialize_RevertWhen_ZeroAdmin() public {
            DualCrossReferencePriceFeedFactory impl = new DualCrossReferencePriceFeedFactory();
    
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
            DualCrossReferencePriceFeedFactory factory = DualCrossReferencePriceFeedFactory(address(proxy));
    
            vm.expectRevert(DualCrossReferencePriceFeedFactory.InvalidAddress.selector);
            factory.initialize(address(0));
        }

    function test_create_AlwaysCreatesDualCrossReferencePriceFeed() public {
            DualCrossReferencePriceFeedFactory impl = new DualCrossReferencePriceFeedFactory();
            ERC1967Proxy proxy = new ERC1967Proxy(address(impl), "");
            DualCrossReferencePriceFeedFactory factory = DualCrossReferencePriceFeedFactory(address(proxy));

            // initialize with a non-zero admin to satisfy initializer check
            factory.initialize(address(this));

            address assetX = address(0x1);
            address assetXAssetYOracleFeed = makeAddr("feedXY");
            address assetYUsdOracleFeed = makeAddr("feedYUSD");

            // DualCrossReferencePriceFeed constructor calls decimals() on both feeds
            vm.mockCall(assetXAssetYOracleFeed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
            vm.mockCall(assetYUsdOracleFeed, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));

            // Only check that the event signature matches (can't predict deployed address)
            vm.expectEmit(false, false, false, false);
            emit DualCrossReferencePriceFeedFactory.DualCrossReferencePriceFeedCreated(
                address(0), assetX, assetXAssetYOracleFeed, assetYUsdOracleFeed
            );

            address priceFeed = factory.create(assetX, assetXAssetYOracleFeed, assetYUsdOracleFeed);

            assertTrue(priceFeed != address(0), "priceFeed should be deployed");
        }
}