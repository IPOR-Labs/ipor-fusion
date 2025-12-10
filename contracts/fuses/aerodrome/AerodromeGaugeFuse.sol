// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFuseCommon} from "../IFuseCommon.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";
import {IGauge} from "./ext/IGauge.sol";
import {AerodromeSubstrateLib, AerodromeSubstrate, AerodromeSubstrateType} from "./AreodromeLib.sol";

/// @notice Structure containing data for entering the Aerodrome gauge fuse
/// @param gaugeAddress The address of the Aerodrome gauge contract
/// @param amount The amount of staking tokens to deposit into the gauge
struct AerodromeGaugeFuseEnterData {
    address gaugeAddress;
    uint256 amount;
}

/// @notice Structure containing data for exiting the Aerodrome gauge fuse
/// @param gaugeAddress The address of the Aerodrome gauge contract
/// @param amount The amount of staking tokens to withdraw from the gauge
struct AerodromeGaugeFuseExitData {
    address gaugeAddress;
    uint256 amount;
}

/// @title AerodromeGaugeFuse
/// @notice Fuse for depositing and withdrawing staking tokens from Aerodrome protocol gauges
/// @dev This fuse allows Plasma Vault to interact with Aerodrome gauges by depositing staking tokens
///      to earn rewards or withdrawing previously deposited tokens. The gauge address must be granted
///      as a substrate for the specified MARKET_ID. The fuse handles token approvals and ensures
///      that only the available balance is deposited/withdrawn.
/// @author IPOR Labs
contract AerodromeGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    /// @notice The address of this fuse version for tracking purposes
    address public immutable VERSION;

    /// @notice The market ID associated with this fuse
    /// @dev This ID is used to validate that gauge addresses are granted as substrates for this market
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when attempting to interact with a gauge that is not granted as a substrate
    /// @param action The operation that failed (e.g., "enter" or "exit")
    /// @param gaugeAddress The address of the gauge that is not supported
    error AerodromeGaugeFuseUnsupportedGauge(string action, address gaugeAddress);

    /// @notice Thrown when a gauge address is zero
    error AerodromeGaugeFuseInvalidGauge();

    /// @notice Event emitted when tokens are deposited into a gauge
    /// @param version The version identifier of this fuse contract
    /// @param gaugeAddress The address of the gauge where tokens were deposited
    /// @param amount The amount of staking tokens deposited (may be less than requested if balance is insufficient)
    event AerodromeGaugeFuseEnter(address indexed version, address indexed gaugeAddress, uint256 amount);

    /// @notice Event emitted when tokens are withdrawn from a gauge
    /// @param version The version identifier of this fuse contract
    /// @param gaugeAddress The address of the gauge from which tokens were withdrawn
    /// @param amount The amount of staking tokens withdrawn (may be less than requested if balance is insufficient)
    event AerodromeGaugeFuseExit(address indexed version, address indexed gaugeAddress, uint256 amount);

    /// @notice Constructor to initialize the fuse with a market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to validate that gauge addresses are granted as substrates.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Deposits staking tokens into an Aerodrome gauge
    /// @param data_ The data containing gauge address and amount to deposit
    /// @return gaugeAddress The address of the gauge where tokens were deposited
    /// @return amount The actual amount of tokens deposited (may be less than requested if balance is insufficient)
    /// @dev Validates that the gauge address is not zero and is granted as a substrate for the market.
    ///      If the requested amount is zero, returns early without performing any operations.
    ///      Deposits only the available balance if it's less than the requested amount.
    ///      Automatically handles token approvals and cleans them up after the operation.
    /// @custom:revert AerodromeGaugeFuseInvalidGauge When gauge address is zero
    /// @custom:revert AerodromeGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function enter(AerodromeGaugeFuseEnterData memory data_) public returns (address gaugeAddress, uint256 amount) {
        if (data_.gaugeAddress == address(0)) {
            revert AerodromeGaugeFuseInvalidGauge();
        }

        gaugeAddress = data_.gaugeAddress;

        if (data_.amount == 0) {
            amount = 0;
            return (gaugeAddress, amount);
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: AerodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert AerodromeGaugeFuseUnsupportedGauge("enter", data_.gaugeAddress);
        }

        address stakingToken = IGauge(data_.gaugeAddress).stakingToken();

        if (stakingToken == address(0)) {
            revert AerodromeGaugeFuseInvalidGauge();
        }

        uint256 balance = IERC20(stakingToken).balanceOf(address(this));

        uint256 amountToDeposit = data_.amount > balance ? balance : data_.amount;

        if (amountToDeposit == 0) {
            amount = 0;
            return (gaugeAddress, amount);
        }

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, amountToDeposit);

        IGauge(data_.gaugeAddress).deposit(amountToDeposit);

        IERC20(stakingToken).forceApprove(data_.gaugeAddress, 0);

        amount = amountToDeposit;

        emit AerodromeGaugeFuseEnter(VERSION, gaugeAddress, amount);
    }

    /// @notice Withdraws staking tokens from an Aerodrome gauge
    /// @param data_ The data containing gauge address and amount to withdraw
    /// @return gaugeAddress The address of the gauge from which tokens were withdrawn
    /// @return amount The actual amount of tokens withdrawn (may be less than requested if balance is insufficient)
    /// @dev Validates that the gauge address is not zero and is granted as a substrate for the market.
    ///      If the requested amount is zero, returns early without performing any operations.
    ///      Withdraws only the available balance if it's less than the requested amount.
    /// @custom:revert AerodromeGaugeFuseInvalidGauge When gauge address is zero
    /// @custom:revert AerodromeGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function exit(AerodromeGaugeFuseExitData memory data_) public returns (address gaugeAddress, uint256 amount) {
        if (data_.gaugeAddress == address(0)) {
            revert AerodromeGaugeFuseInvalidGauge();
        }

        gaugeAddress = data_.gaugeAddress;

        if (data_.amount == 0) {
            amount = 0;
            return (gaugeAddress, amount);
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                AerodromeSubstrateLib.substrateToBytes32(
                    AerodromeSubstrate({
                        substrateAddress: data_.gaugeAddress,
                        substrateType: AerodromeSubstrateType.Gauge
                    })
                )
            )
        ) {
            revert AerodromeGaugeFuseUnsupportedGauge("exit", data_.gaugeAddress);
        }

        uint256 balance = IGauge(data_.gaugeAddress).balanceOf(address(this));

        uint256 amountToWithdraw = data_.amount > balance ? balance : data_.amount;

        if (amountToWithdraw == 0) {
            amount = 0;
            return (gaugeAddress, amount);
        }

        IGauge(data_.gaugeAddress).withdraw(amountToWithdraw);

        amount = amountToWithdraw;

        emit AerodromeGaugeFuseExit(VERSION, gaugeAddress, amount);
    }

    /// @notice Enters the Fuse using transient storage for parameters
    /// @dev Reads gauge address and amount from transient storage inputs.
    ///      Writes returned gaugeAddress and amount to transient storage outputs.
    ///      This method enables the fuse to be called through transient storage mechanism.
    /// @custom:revert AerodromeGaugeFuseInvalidGauge When gauge address is zero or staking token is zero
    /// @custom:revert AerodromeGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function enterTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address gaugeAddress = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedGaugeAddress, uint256 returnedAmount) = enter(
            AerodromeGaugeFuseEnterData(gaugeAddress, amount)
        );

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedGaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Exits the Fuse using transient storage for parameters
    /// @dev Reads gauge address and amount from transient storage inputs.
    ///      Writes returned gaugeAddress and amount to transient storage outputs.
    ///      This method enables the fuse to be called through transient storage mechanism.
    /// @custom:revert AerodromeGaugeFuseInvalidGauge When gauge address is zero
    /// @custom:revert AerodromeGaugeFuseUnsupportedGauge When gauge is not granted as a substrate
    function exitTransient() external {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        address gaugeAddress = TypeConversionLib.toAddress(inputs[0]);
        uint256 amount = TypeConversionLib.toUint256(inputs[1]);

        (address returnedGaugeAddress, uint256 returnedAmount) = exit(AerodromeGaugeFuseExitData(gaugeAddress, amount));

        bytes32[] memory outputs = new bytes32[](2);
        outputs[0] = TypeConversionLib.toBytes32(returnedGaugeAddress);
        outputs[1] = TypeConversionLib.toBytes32(returnedAmount);
        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
