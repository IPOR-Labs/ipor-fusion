// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {IAddressesRegistry} from "./ext/IAddressesRegistry.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {IStabilityPool} from "./ext/IStabilityPool.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/**
 * @dev data structure used for entering the Liquity Stability Pool by providing BOLD to it
 * @param registry The registry to which the stability pool is registered
 * @param amount The amount of BOLD to provide
 */
struct LiquityStabilityPoolFuseEnterData {
    address registry;
    uint256 amount;
}

/**
 * @dev data structure used for exiting the Liquity Stability Pool by withdrawing BOLD and rewards from it
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
    address public immutable VERSION;

    error UnsupportedSubstrate();

    event LiquityStabilityPoolFuseEnter(address stabilityPool, uint256 amount);
    event LiquityStabilityPoolFuseExit(address stabilityPool, uint256 amount);

    constructor(uint256 marketId) {
        MARKET_ID = marketId;
        VERSION = address(this);
    }

    /**
     * @notice Enters the Liquity Stability Pool by providing a specified amount of BOLD.
     *         Collateral rewards are not claimed during this operation.
     * @param data_ Contains the registry address and amount of BOLD to deposit.
     * @return stabilityPool The address of the stability pool
     * @return amount The amount of BOLD deposited
     */
    function enter(
        LiquityStabilityPoolFuseEnterData memory data_
    ) public returns (address stabilityPool, uint256 amount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.registry)) {
            revert UnsupportedSubstrate();
        }

        amount = data_.amount;
        IAddressesRegistry registry = IAddressesRegistry(data_.registry);
        IStabilityPool stabilityPoolContract = IStabilityPool(registry.stabilityPool());
        stabilityPool = address(stabilityPoolContract);

        if (amount == 0) {
            emit LiquityStabilityPoolFuseEnter(stabilityPool, amount);
            return (stabilityPool, amount);
        }

        address boldToken = registry.boldToken();

        ERC20(boldToken).forceApprove(stabilityPool, amount);
        /// @dev do not claim collateral when entering so to avoid to swap them now
        /// the principle is that we can empty the vault by entering the stability pool
        stabilityPoolContract.provideToSP(amount, false);
        ERC20(boldToken).forceApprove(stabilityPool, 0);

        emit LiquityStabilityPoolFuseEnter(stabilityPool, amount);
    }

    /**
     * @notice Exits the Liquity Stability Pool by withdrawing a specified amount of BOLD and claiming all collateral rewards.
     *         If the amount is zero and there are no deposits, it will only claim any remaining collateral rewards.
     * @param data_ Contains the registry address and amount of BOLD to withdraw.
     * @return stabilityPool The address of the stability pool
     * @return amount The amount of BOLD withdrawn
     */
    function exit(
        LiquityStabilityPoolFuseExitData memory data_
    ) public returns (address stabilityPool, uint256 amount) {
        if (!PlasmaVaultConfigLib.isSubstrateAsAssetGranted(MARKET_ID, data_.registry)) {
            revert UnsupportedSubstrate();
        }
        IAddressesRegistry registry = IAddressesRegistry(data_.registry);
        IStabilityPool stabilityPoolContract = IStabilityPool(registry.stabilityPool());
        stabilityPool = address(stabilityPoolContract);
        amount = data_.amount;

        if (amount == 0) {
            if (stabilityPoolContract.deposits(address(this)) == 0) {
                stabilityPoolContract.claimAllCollGains();
            }
            emit LiquityStabilityPoolFuseExit(stabilityPool, amount);
            return (stabilityPool, amount);
        }
        /// @dev always claim collateral when exiting
        /// the principle is that we can close our stability pool position by exiting it
        stabilityPoolContract.withdrawFromSP(amount, true);

        emit LiquityStabilityPoolFuseExit(stabilityPool, amount);
    }

    /**
     * @notice Enters the Liquity Stability Pool using transient storage for parameters
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address registry = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address stabilityPool, uint256 returnedAmount) = enter(LiquityStabilityPoolFuseEnterData(registry, amount));

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(stabilityPool);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Exits the Liquity Stability Pool using transient storage for parameters
     */
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);
        address registry = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address stabilityPool, uint256 returnedAmount) = exit(LiquityStabilityPoolFuseExitData(registry, amount));

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(stabilityPool);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
