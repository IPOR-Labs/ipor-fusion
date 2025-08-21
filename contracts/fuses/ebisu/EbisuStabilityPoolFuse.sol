// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";

/**
 * @dev Data structure used for entering the Ebisu Stability Pool by providing ebUSD to it
 * @param registry The registry to which the stability pool is registered
 * @param amount The amount of ebUSD to provide
 */
struct EbisuStabilityPoolFuseEnterData {
    address registry;
    uint256 amount;
}

/**
 * @dev Data structure used for exiting the Ebisu Stability Pool by withdrawing ebUSD and rewards from it
 * @param registry The registry to which the stability pool is registered
 * @param amount The amount of ebUSD to withdraw (collateral is always totally withdrawn)
 */
struct EbisuStabilityPoolFuseExitData {
    address registry;
    uint256 amount;
}

/**
 * @title EbisuStabilityPoolFuse.sol
 * @dev A smart contract for interacting with the Ebisu Stability Pool by providing ebUSD to it,
 * and withdraw ebUSD and collateral tokens as rewards from it
 */
contract EbisuStabilityPoolFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    error InvalidMarketId();
    error UnsupportedSubstrate();

    event EbisuStabilityPoolFuseEnter(address stabilityPool, uint256 amount);
    event EbisuStabilityPoolFuseExit(address stabilityPool, uint256 amount);

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    /**
     * @dev Enters the Ebisu Stability Pool by providing a specified amount of ebUSD.
     *      Collateral rewards are not claimed during this operation.
     * @param data Contains the registry address and amount of ebUSD to deposit.
     */

    function enter(EbisuStabilityPoolFuseEnterData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) {
            revert UnsupportedSubstrate();
        }

        if (data.amount == 0) return;
        IAddressesRegistry registry = IAddressesRegistry(data.registry);
        IStabilityPool stabilityPool = IStabilityPool(registry.stabilityPool());
        address ebusdToken = registry.boldToken();

        ERC20(ebusdToken).forceApprove(address(stabilityPool), data.amount);
        // do not claim collateral when entering so to avoid to swap them now
        // the principle is that we can empty the vault by entering the stability pool
        stabilityPool.provideToSP(data.amount, false);
        ERC20(ebusdToken).forceApprove(address(stabilityPool), 0);

        emit EbisuStabilityPoolFuseEnter(address(stabilityPool), data.amount);
    }

    /**
     * @dev Exits the Ebisu Stability Pool by withdrawing a specified amount of ebUSD and claiming all collateral rewards.
     *      If the amount is zero and there are no deposits, it will only claim any remaining collateral rewards.
     * @param data Contains the registry address and amount of ebUSD to withdraw.
     */

    function exit(EbisuStabilityPoolFuseExitData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) {
            revert UnsupportedSubstrate();
        }
        IStabilityPool stabilityPool = IStabilityPool(IAddressesRegistry(data.registry).stabilityPool());

        if (data.amount == 0) {
            if (stabilityPool.deposits(address(this)) == 0) {
                stabilityPool.claimAllCollGains();
                return;
            }
            return;
        }
        // always claim collateral when exiting
        // the principle is that we can close our stability pool position by exiting it
        stabilityPool.withdrawFromSP(data.amount, true);

        emit EbisuStabilityPoolFuseExit(address(stabilityPool), data.amount);
    }
}
