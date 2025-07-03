// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {Errors} from "../../libraries/errors/Errors.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {FuseStorageLib} from "../../libraries/FuseStorageLib.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";

contract LiquityStabilityPoolFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;
    address public immutable VERSION;

    // We fix only one registry for each vault, to allow more granularity
    IAddressesRegistry public immutable registry;
    IStabilityPool public immutable stabilityPool;
    address public immutable boldToken;

    error ZeroAmount();

    event LiquityStabilityPoolFuseEnter(address version, address stabilityPool, uint256 amount);

    constructor(uint256 marketId_, address _registry) {
        VERSION = address(this);
        MARKET_ID = marketId_;
        registry = IAddressesRegistry(_registry);
        stabilityPool = IStabilityPool(registry.stabilityPool());
        boldToken = registry.boldToken();
    }

    function enter(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();

        ERC20(boldToken).forceApprove(address(stabilityPool), amount);
        // do not claim collateral when entering so to avoid to swap them now
        // the principle is that we can empty the vault by entering the stability pool
        stabilityPool.provideToSP(amount, false);
        ERC20(boldToken).forceApprove(address(stabilityPool), 0);

        emit LiquityStabilityPoolFuseEnter(VERSION, address(stabilityPool), amount);
    }

    function exit(uint256 amount) external {
        if (amount == 0) {
            if (stabilityPool.deposits(address(this)) == 0) {
                // if the vault has no deposits, we call the claimAllCollGains function
                stabilityPool.claimAllCollGains();
                return;
            }
            revert ZeroAmount();
        }
        // always claim collateral when exiting, and swap it to BOLD
        // the principle is that we can close our stability pool position by exiting it
        stabilityPool.withdrawFromSP(amount, true);
    }
}
