// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";

/**
 * @dev Data structure used for entering the Liquity Stability Pool by providing BOLD to it
 * @param registry The registry to which the stability pool is registered
 * @param amount The amount of BOLD to provide
 */
struct LiquityStabilityPoolFuseEnterData {
    address registry;
    uint256 amount;
}

/**
 * @dev Data structure used for exiting the Liquity Stability Pool by withdrawing BOLD and rewards from it
 * @param registry The registry to which the stability pool is registered
 * @param amount The amount of BOLD to withdraw (collateral is always totally withdrawn)
 */
struct LiquityStabilityPoolFuseExitData {
    address registry;
    uint256 amount;
}

/**
 * @title LiquityStabilityPoolFuse.sol
 * @dev A smart contract for interacting with the Liquity Stability Pool by providing BOLD to it,
 * and withdraw BOLD and collateral tokens as rewards from it
 */
contract LiquityStabilityPoolFuse is IFuseCommon {
    using SafeERC20 for ERC20;

    uint256 public immutable MARKET_ID;

    error InvalidMarketId();
    error UnsupportedSubstrate();

    event LiquityStabilityPoolFuseEnter(address stabilityPool, uint256 amount);
    event LiquityStabilityPoolFuseExit(address stabilityPool, uint256 amount);

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
    }

    /**
     * @dev Enters the Liquity Stability Pool by providing a specified amount of BOLD.
     *      Collateral rewards are not claimed during this operation.
     * @param data Contains the registry address and amount of BOLD to deposit.
     */

    function enter(LiquityStabilityPoolFuseEnterData memory data) external {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data.registry)) {
            revert UnsupportedSubstrate();
        }

        if (data.amount == 0) return;
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

    /**
     * @dev Exits the Liquity Stability Pool by withdrawing a specified amount of BOLD and claiming all collateral rewards.
     *      If the amount is zero and there are no deposits, it will only claim any remaining collateral rewards.
     * @param data Contains the registry address and amount of BOLD to withdraw.
     */

    function exit(LiquityStabilityPoolFuseExitData memory data) external {
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

        emit LiquityStabilityPoolFuseExit(address(stabilityPool), data.amount);
    }
}
