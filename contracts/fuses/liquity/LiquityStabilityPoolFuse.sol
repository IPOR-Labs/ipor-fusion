// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {IporFusionMarkets} from "../../libraries/IporFusionMarkets.sol";

contract LiquityStabilityPoolFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    error ZeroAmount();
    error InvalidMarketId();
    error UnsupportedSubstrate();

    event LiquityStabilityPoolFuseEnter(address stabilityPool, uint256 amount);
    event LiquityStabilityPoolFuseExit(address stabilityPool, uint256 amount);

    struct LiquityStabilityPoolFuseEnterData {
        address registry;
        uint256 amount;
    }

    struct LiquityStabilityPoolFuseExitData {
        address registry;
        uint256 amount;
    }

    constructor(uint256 marketId) {
        if (marketId != IporFusionMarkets.LIQUITY_V2) revert InvalidMarketId();
        MARKET_ID = marketId;
    }

    function enter(LiquityStabilityPoolFuseEnterData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) {
            revert UnsupportedSubstrate();
        }

        if (data.amount == 0) revert ZeroAmount();
        IAddressesRegistry registry = IAddressesRegistry(data.registry);
        IStabilityPool stabilityPool = IStabilityPool(registry.stabilityPool());
        address boldToken = registry.boldToken();

        ERC20(boldToken).forceApprove(address(stabilityPool), data.amount);
        // do not claim collateral when entering so to avoid to swap them now
        // the principle is that we can empty the vault by entering the stability pool
        stabilityPool.provideToSP(data.amount, false);
        ERC20(boldToken).forceApprove(address(stabilityPool), 0);

        emit LiquityStabilityPoolFuseEnter(address(stabilityPool), data.amount);
    }

    function exit(LiquityStabilityPoolFuseExitData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) {
            revert UnsupportedSubstrate();
        }
        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(data.registry).stabilityPool());

        if (data.amount == 0) {
            if (stabilityPool.deposits(address(this)) == 0) {
                // if the vault has no deposits, we call the claimAllCollGains function
                stabilityPool.claimAllCollGains();
                return;
            }
            revert ZeroAmount();
        }
        // always claim collateral when exiting, and swap it to BOLD
        // the principle is that we can close our stability pool position by exiting it
        stabilityPool.withdrawFromSP(data.amount, true);

        emit LiquityStabilityPoolFuseExit(address(stabilityPool), data.amount);
    }
}
