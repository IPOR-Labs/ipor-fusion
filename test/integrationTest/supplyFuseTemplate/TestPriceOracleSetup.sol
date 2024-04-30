// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {console2} from "forge-std/Test.sol";
import {TestStorage} from "./TestStorage.sol";
import {IporPriceOracle} from "../../../contracts/priceOracle/IporPriceOracle.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

abstract contract TestPriceOracleSetup is TestStorage {
    function initPriceOracle() public {
        console2.log("initPriceOracle");
        address owner = getOwner();
        vm.startPrank(owner);

        IporPriceOracle implementation = new IporPriceOracle(
            0x0000000000000000000000000000000000000348,
            8,
            0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf
        );

        priceOracle = address(
            new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address)", owner))
        );

        (address[] memory assets, address[] memory sources) = setupPriceOracle();
        if (assets.length == 0) {
            return;
        }
        IporPriceOracle(priceOracle).setAssetSources(assets, sources);
        vm.stopPrank();
    }

    function setupPriceOracle() public virtual returns (address[] memory assets, address[] memory sources);
}
