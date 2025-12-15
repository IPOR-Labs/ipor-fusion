// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {TestStorage} from "./TestStorage.sol";
import {PriceOracleMiddleware} from "../../../contracts/price_oracle/PriceOracleMiddleware.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract TestPriceOracleSetup is TestStorage {
    function initPriceOracle() public {
        address owner = getOwner();
        vm.startPrank(owner);

        PriceOracleMiddleware implementation = new PriceOracleMiddleware(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf);

        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        (address[] memory assets, address[] memory sources) = setupPriceOracle();
        if (assets.length == 0) {
            return;
        }
        PriceOracleMiddleware(priceOracle).setAssetsPricesSources(assets, sources);
        vm.stopPrank();
    }

    function setupPriceOracle() public virtual returns (address[] memory assets, address[] memory sources);
}
