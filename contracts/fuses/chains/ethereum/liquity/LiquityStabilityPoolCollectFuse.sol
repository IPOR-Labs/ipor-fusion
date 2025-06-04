// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../../../IFuseCommon.sol";
import {Errors} from "../../../../libraries/errors/Errors.sol";
import {FuseStorageLib} from "../../../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {IPriceFeed} from "./ext/IPriceFeed.sol";

contract LiquityStabilityPoolFuse is IFuseCommon {
    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    // We fix only one registry for each vault, to allow more granularity
    IAddressesRegistry public immutable registry;
    IStabilityPool public immutable stabilityPool;
    address public immutable boldToken;

    error InvalidRegistry();

    constructor(uint256 marketId_, address _registry) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        registry = IAddressesRegistry(_registry);
        stabilityPool = IStabilityPool(registry.stabilityPool());
        boldToken = registry.boldToken();
    }

    function enter() external {
        stabilityPool.claimAllCollGains();
    }
}
