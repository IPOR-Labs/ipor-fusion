// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFuseCommon} from "../IFuseCommon.sol";
import {BalancerSubstrateLib, BalancerSubstrateType, BalancerSubstrate} from "./BalancerSubstrateLib.sol";
import {ILiquidityGauge} from "./ext/ILiquidityGauge.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {TransientStorageLib} from "../../transient_storage/TransientStorageLib.sol";
import {TypeConversionLib} from "../../libraries/TypeConversionLib.sol";

/**
 * @notice Data structure for depositing BPT tokens into a Balancer gauge
 * @param gaugeAddress The address of the Balancer liquidity gauge
 * @param bptAmount The amount of BPT tokens to deposit
 * @param minBptAmount The minimum amount of BPT tokens that must be deposited
 */
struct BalancerGaugeFuseEnterData {
    address gaugeAddress;
    uint256 bptAmount;
    uint256 minBptAmount;
}

/**
 * @notice Data structure for withdrawing BPT tokens from a Balancer gauge
 * @param gaugeAddress The address of the Balancer liquidity gauge
 * @param bptAmount The amount of BPT tokens to withdraw
 * @param minBptAmount The minimum amount of BPT tokens that must be withdrawn
 */
struct BalancerGaugeFuseExitData {
    address gaugeAddress;
    uint256 bptAmount;
    uint256 minBptAmount;
}

/**
 * @title BalancerGaugeFuse
 * @notice A fuse contract that handles BPT token deposits and withdrawals with Balancer liquidity gauges
 *         within the IPOR Fusion vault system
 * @dev This contract implements the IFuseCommon interface and provides functionality for
 *      depositing and withdrawing BPT tokens from Balancer liquidity gauges.
 *      Gauges are used to earn rewards for providing liquidity to Balancer pools.
 *
 * Key Features:
 * - Deposit BPT tokens into Balancer liquidity gauges
 * - Withdraw BPT tokens from Balancer liquidity gauges
 * - Substrate validation to ensure only authorized gauges are used
 * - Comprehensive event logging for operation tracking
 *
 * Architecture:
 * - Each fuse is tied to a specific market ID
 * - Validates gauge access through the substrate system before executing operations
 * - Supports both enter and exit operations with minimum amount validation
 *
 * Security Considerations:
 * - Immutable market ID prevents configuration changes
 * - Substrate validation prevents unauthorized gauge access
 * - Minimum amount validation ensures operations meet requirements
 * - Uses SafeERC20 for secure token operations
 *
 * Usage:
 * - Enter: Deposit BPT tokens into a gauge to start earning rewards
 * - Exit: Withdraw BPT tokens from a gauge
 */
contract BalancerGaugeFuse is IFuseCommon {
    using SafeERC20 for IERC20;

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;

    /// @notice Thrown when attempting to use a gauge that is not granted for this market
    /// @param gaugeAddress The address of the gauge that was not granted
    /// @custom:error BalancerGaugeFuseUnsupportedGauge
    error BalancerGaugeFuseUnsupportedGauge(address gaugeAddress);

    /// @notice Thrown when the actual deposit/withdraw amount is less than the minimum required
    /// @param gaugeAddress The address of the gauge
    /// @param bptAmount The requested BPT amount
    /// @param minBptAmount The minimum required BPT amount
    /// @custom:error BalancerGaugeFuseInsufficientBptAmount
    error BalancerGaugeFuseInsufficientBptAmount(address gaugeAddress, uint256 bptAmount, uint256 minBptAmount);

    /// @notice Emitted when BPT tokens are deposited into a Balancer gauge
    /// @param version The address of the fuse contract version
    /// @param gaugeAddress The address of the Balancer liquidity gauge
    /// @param bptAmount The amount of BPT tokens that were deposited
    event BalancerGaugeFuseEnter(address indexed version, address indexed gaugeAddress, uint256 bptAmount);

    /// @notice Emitted when BPT tokens are withdrawn from a Balancer gauge
    /// @param version The address of the fuse contract version
    /// @param gaugeAddress The address of the Balancer liquidity gauge
    /// @param bptAmount The amount of BPT tokens that were withdrawn
    event BalancerGaugeFuseExit(address indexed version, address indexed gaugeAddress, uint256 bptAmount);

    /// @notice Constructor to initialize the fuse with market ID
    /// @param marketId_ The unique identifier for the market configuration
    /// @dev The market ID is used to retrieve the list of substrates (gauges) that this fuse will track.
    ///      VERSION is set to the address of this contract instance for tracking purposes.
    constructor(uint256 marketId_) {
        VERSION = address(this);
        MARKET_ID = marketId_;
    }

    /// @notice Deposits BPT tokens into a Balancer liquidity gauge
    /// @param data_ Parameters for gauge deposit operation
    /// @return depositAmount The actual amount of BPT tokens that were deposited
    /// @dev Validates gauge substrate, checks available balance, and ensures minimum amount requirement.
    ///      Returns 0 if bptAmount is 0. Deposits only available balance if it's less than requested.
    ///      Automatically handles token approvals and cleans them up after the operation.
    function enter(BalancerGaugeFuseEnterData memory data_) public payable returns (uint256 depositAmount) {
        if (data_.bptAmount == 0) {
            return 0;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({
                        substrateType: BalancerSubstrateType.GAUGE,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert BalancerGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }
        address lpToken = ILiquidityGauge(data_.gaugeAddress).lp_token();
        uint256 balanceOfPlasmaVault = IERC20(lpToken).balanceOf(address(this));

        depositAmount = data_.bptAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.bptAmount;

        if (depositAmount < data_.minBptAmount) {
            revert BalancerGaugeFuseInsufficientBptAmount(data_.gaugeAddress, data_.bptAmount, data_.minBptAmount);
        }

        IERC20(lpToken).forceApprove(data_.gaugeAddress, depositAmount);
        ILiquidityGauge(data_.gaugeAddress).deposit(depositAmount, address(this), false);

        emit BalancerGaugeFuseEnter(VERSION, data_.gaugeAddress, depositAmount);
    }

    /// @notice Deposits BPT into a gauge using transient storage for input parameters
    /// @dev Reads inputs from transient storage, calls enter(), and writes outputs to transient storage
    function enterTransient() external payable {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        BalancerGaugeFuseEnterData memory data = BalancerGaugeFuseEnterData({
            gaugeAddress: TypeConversionLib.toAddress(inputs[0]),
            bptAmount: TypeConversionLib.toUint256(inputs[1]),
            minBptAmount: TypeConversionLib.toUint256(inputs[2])
        });

        uint256 depositAmount = enter(data);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(depositAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }

    /// @notice Withdraws BPT tokens from a Balancer liquidity gauge
    /// @param data_ Parameters for gauge withdrawal operation
    /// @return withdrawAmount The actual amount of BPT tokens that were withdrawn
    /// @dev Validates gauge substrate, checks available balance, and ensures minimum amount requirement.
    ///      Returns 0 if bptAmount is 0. Withdraws only available balance if it's less than requested.
    function exit(BalancerGaugeFuseExitData memory data_) public payable returns (uint256 withdrawAmount) {
        if (data_.bptAmount == 0) {
            return 0;
        }

        if (
            !PlasmaVaultConfigLib.isMarketSubstrateGranted(
                MARKET_ID,
                BalancerSubstrateLib.substrateToBytes32(
                    BalancerSubstrate({
                        substrateType: BalancerSubstrateType.GAUGE,
                        substrateAddress: data_.gaugeAddress
                    })
                )
            )
        ) {
            revert BalancerGaugeFuseUnsupportedGauge(data_.gaugeAddress);
        }

        uint256 balanceOfPlasmaVault = IERC20(data_.gaugeAddress).balanceOf(address(this));

        withdrawAmount = data_.bptAmount > balanceOfPlasmaVault ? balanceOfPlasmaVault : data_.bptAmount;

        if (withdrawAmount < data_.minBptAmount) {
            revert BalancerGaugeFuseInsufficientBptAmount(data_.gaugeAddress, data_.bptAmount, data_.minBptAmount);
        }

        ILiquidityGauge(data_.gaugeAddress).withdraw(withdrawAmount, false);

        emit BalancerGaugeFuseExit(VERSION, data_.gaugeAddress, withdrawAmount);
    }

    /// @notice Withdraws BPT from a gauge using transient storage for input parameters
    /// @dev Reads inputs from transient storage, calls exit(), and writes outputs to transient storage
    function exitTransient() external payable {
        bytes32[] memory inputs = TransientStorageLib.getInputs(VERSION);

        BalancerGaugeFuseExitData memory data = BalancerGaugeFuseExitData({
            gaugeAddress: TypeConversionLib.toAddress(inputs[0]),
            bptAmount: TypeConversionLib.toUint256(inputs[1]),
            minBptAmount: TypeConversionLib.toUint256(inputs[2])
        });

        uint256 withdrawAmount = exit(data);

        bytes32[] memory outputs = new bytes32[](1);
        outputs[0] = TypeConversionLib.toBytes32(withdrawAmount);

        TransientStorageLib.setOutputs(VERSION, outputs);
    }
}
