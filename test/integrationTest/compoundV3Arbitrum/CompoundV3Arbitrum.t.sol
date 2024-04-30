// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {SupplyTest} from "../supplyFuseTemplate/SupplyTests.sol";

contract CompoundV3Arbitrum {
    function testShouldWork() external {
        //        assertTrue(true, "It should work");
    }

    function dealAssets(address account_, uint256 amount_) public {
        // TODO: Implement
    }

    function setupAsset() public {
        //        asset = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    }

    function setupPriceOracle() public returns (address[] memory assets, address[] memory sources) {
        assets = new address[](0);
        sources = new address[](0);
    }
}
