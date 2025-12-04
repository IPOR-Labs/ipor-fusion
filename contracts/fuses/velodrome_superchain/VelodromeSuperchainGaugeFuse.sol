// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {ILeafGauge} from "./ext/ILeafGauge.sol";
import {VelodromeSuperchainSubstrateLib, VelodromeSuperchainSubstrate, VelodromeSuperchainSubstrateType} from "./VelodromeSuperchainLib.sol";

/// @notice Data structure used for entering a gauge deposit operation
/// @param gaugeAddress The address of the Velodrome Superchain gauge contract
/// @param amount The amount of staking tokens to deposit into the gauge
/// @param minAmount The minimum amount that must be deposited (slippage protection)
struct VelodromeSuperchainGaugeFuseEnterData {
    address gaugeAddress;
    uint256 amount;
    uint256 minAmount;
}

/// @notice Data structure used for exiting a gauge withdrawal operation
/// @param gaugeAddress The address of the Velodrome Superchain gauge contract
/// @param amount The amount of staking tokens to withdraw from the gauge
/// @param minAmount The minimum amount that must be withdrawn (slippage protection)
struct VelodromeSuperchainGaugeFuseExitData {
    address gaugeAddress;
    uint256 amount;
    uint256 minAmount;
}

/// @notice Data structure returned from enter and exit operations
/// @param gaugeAddress The address of the Velodrome Superchain gauge contract
/// @param amount The actual amount deposited or withdrawn
struct VelodromeSuperchainGaugeFuseResult {
    address gaugeAddress;
    uint256 amount;
}

/**
 * @title VelodromeSuperchainGaugeFuse
 * @notice Fuse contract for depositing and withdrawing staking tokens to/from Velodrome Superchain gauges
 * @dev This contract allows the Plasma Vault to interact with Velodrome Superchain gauge contracts,
 *      enabling staking of LP tokens to earn rewards. It validates gauge addresses, checks substrate
 *      permissions, handles balance checks, and enforces minimum amount requirements. Supports both
 *      standard and transient storage patterns for gas-efficient operations.
 * @author IPOR Labs
 */
contract VelodromeSuperchainGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    error VelodromeSuperchainGaugeFuseUnsupportedGauge(string action, address gaugeAddress);
    error VelodromeSuperchainGaugeFuseInvalidGauge();
    error VelodromeSuperchainGaugeFuseInvalidAmount();
    error VelodromeSuperchainGaugeFuseMinAmountNotMet();

    event VelodromeSuperchainGaugeFuseEnter(address version, address gaugeAddress, uint256 amount);
    event VelodromeSuperchainGaugeFuseExit(address version, address gaugeAddress, uint256 amount);

    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /**
     * @notice Deposits staking tokens into a Velodrome Superchain gauge
     * @dev Validates the gauge address, checks substrate permissions, retrieves the staking token
     *      from the gauge, checks available balance, and deposits tokens using forceApprove pattern.
     *      Uses the minimum of requested amount and available balance. Reverts if gauge is invalid,
     *      substrate is not granted, or minimum amount requirement is not met.
     * @param data_ The enter data containing gauge address, amount to deposit, and minimum amount
     * @return result The result containing gauge address and actual amount deposited
     * @custom:reverts VelodromeSuperchainGaugeFuseInvalidGauge If gauge address is zero
     * @custom:reverts VelodromeSuperchainGaugeFuseUnsupportedGauge If gauge is not granted as a substrate
     * @custom:reverts VelodromeSuperchainGaugeFuseMinAmountNotMet If deposited amount is below minimum
     */
    function enter(
        VelodromeSuperchainGaugeFuseEnterData memory data_
    ) public returns (VelodromeSuperchainGaugeFuseResult memory result) {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeSuperchainGaugeFuseInvalidGauge();
        }

        result.gaugeAddress = data_.gaugeAddress;

        if (data_.amount == 0) {
            result.amount = 0;
            return result;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeSuperchainGaugeFuseUnsupportedGauge("enter", data_.gaugeAddress);
        }

        address stakingToken = ILeafGauge(data_.gaugeAddress).stakingToken();

        uint256 balance = IERC20(stakingToken).balanceOf(address(this));

        uint256 amountToDeposit = data_.amount > balance ? balance : data_.amount;

        if (amountToDeposit < data_.minAmount) {
            revert VelodromeSuperchainGaugeFuseMinAmountNotMet();
        }

        if (amountToDeposit == 0) {
            result.amount = 0;
            return result;
        }

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, amountToDeposit);

        ILeafGauge(data_.gaugeAddress).deposit(amountToDeposit);

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, 0);

        result.amount = amountToDeposit;

        emit VelodromeSuperchainGaugeFuseEnter(VERSION, result.gaugeAddress, result.amount);
    }

    /**
     * @notice Withdraws staking tokens from a Velodrome Superchain gauge
     * @dev Validates the gauge address, checks substrate permissions, checks available balance
     *      in the gauge, and withdraws tokens. Uses the minimum of requested amount and available
     *      balance. Reverts if gauge is invalid, substrate is not granted, amount is zero,
     *      or minimum amount requirement is not met.
     * @param data_ The exit data containing gauge address, amount to withdraw, and minimum amount
     * @return result The result containing gauge address and actual amount withdrawn
     * @custom:reverts VelodromeSuperchainGaugeFuseInvalidGauge If gauge address is zero
     * @custom:reverts VelodromeSuperchainGaugeFuseInvalidAmount If amount is zero
     * @custom:reverts VelodromeSuperchainGaugeFuseUnsupportedGauge If gauge is not granted as a substrate
     * @custom:reverts VelodromeSuperchainGaugeFuseMinAmountNotMet If withdrawn amount is below minimum
     */
    function exit(
        VelodromeSuperchainGaugeFuseExitData memory data_
    ) public returns (VelodromeSuperchainGaugeFuseResult memory result) {
        if (data_.gaugeAddress == address(0)) {
            revert VelodromeSuperchainGaugeFuseInvalidGauge();
        }

        result.gaugeAddress = data_.gaugeAddress;

        if (data_.amount == 0) {
            revert VelodromeSuperchainGaugeFuseInvalidAmount();
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                VelodromeSuperchainSubstrateLib.substrateToBytes32(
                    VelodromeSuperchainSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: VelodromeSuperchainSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert VelodromeSuperchainGaugeFuseUnsupportedGauge("exit", data_.gaugeAddress);
        }

        uint256 balance = ILeafGauge(data_.gaugeAddress).balanceOf(address(this));

        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw < data_.minAmount) {
            revert VelodromeSuperchainGaugeFuseMinAmountNotMet();
        }

        if (amountToWithdraw == 0) {
            result.amount = 0;
            return result;
        }

        ILeafGauge(data_.gaugeAddress).withdraw(amountToWithdraw);

        result.amount = amountToWithdraw;

        emit VelodromeSuperchainGaugeFuseExit(VERSION, result.gaugeAddress, result.amount);
    }

    /**
     * @notice Enters the Fuse using transient storage for parameters
     * @dev Reads gauge address, amount, and minAmount from transient storage inputs,
     *      calls enter() with the decoded data, and writes the result (gaugeAddress and amount)
     *      to transient storage outputs.
     *      Input 0: gaugeAddress (address)
     *      Input 1: amount (uint256)
     *      Input 2: minAmount (uint256)
     *      Output 0: gaugeAddress (address)
     *      Output 1: amount (uint256)
     */
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainGaugeFuseResult memory result = enter(
            VelodromeSuperchainGaugeFuseEnterData(
                TypeConversionLib.toAddress(inputs[0]),
                TypeConversionLib.toUint256(inputs[1]),
                TypeConversionLib.toUint256(inputs[2])
            )
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(result.gaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(result.amount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /**
     * @notice Exits the Fuse using transient storage for parameters
     * @dev Reads gauge address, amount, and minAmount from transient storage inputs,
     *      calls exit() with the decoded data, and writes the result (gaugeAddress and amount)
     *      to transient storage outputs.
     *      Input 0: gaugeAddress (address)
     *      Input 1: amount (uint256)
     *      Input 2: minAmount (uint256)
     *      Output 0: gaugeAddress (address)
     *      Output 1: amount (uint256)
     */
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        VelodromeSuperchainGaugeFuseResult memory result = exit(
            VelodromeSuperchainGaugeFuseExitData(
                TypeConversionLib.toAddress(inputs[0]),
                TypeConversionLib.toUint256(inputs[1]),
                TypeConversionLib.toUint256(inputs[2])
            )
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(result.gaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(result.amount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
