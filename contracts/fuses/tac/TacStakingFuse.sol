// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingExecutor, StakingExecutorTacDelegateData, StakingExecutorTacRedelegateData, StakingExecutorTacUndelegateData} from "./TacStakingExecutor.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./TacValidatorAddressConverter.sol";

/// @notice Enum to represent the action type for entering the fuse
/// @dev DELEGATE - delegate to a validator
/// @dev REDELEGATE - redelegate from one validator to another
enum TacStakingFuseEnterAction {
    DELEGATE,
    REDELEGATE
}

/// @notice Struct to represent the action data for entering the fuse
/// @dev action - the action type
/// @dev validatorSrcAddress - the source validator address
/// @dev validatorDstAddress - the destination validator address, zero address for delegate
/// @dev wTacAmount - the amount of TAC to delegate, zero for redelegate
struct TacStakingFuseEnterActionData {
    TacStakingFuseEnterAction action;
    string validatorSrcAddress;
    string validatorDstAddress;
    uint256 wTacAmount;
}

/// @notice Struct to represent the data for entering the fuse
/// @dev actions - the array of action data
struct TacStakingFuseEnterData {
    TacStakingFuseEnterActionData[] actions;
}

/// @notice Struct to represent the data for exiting the fuse
/// @dev validators - the array of validator addresses
/// @dev wTacAmounts - the array of amounts of wTAC to unstake
struct TacStakingFuseExitData {
    string[] validators;
    uint256[] wTacAmounts;
}

contract TacStakingFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    error TacStakingFuseInvalidExecutorAddress();
    error TacStakingFuseSubstrateNotGranted(string validator);
    error TacStakingFuseExecutorAlreadyCreated();
    error TacStakingFuseArrayLengthMismatch();
    error TacStakingFuseEmptyArray();
    error TacStakingFuseInvalidAction();
    error TacStakingFuseInvalidValidatorDstAddress();
    event TacStakingFuseEnter(
        address version,
        TacStakingFuseEnterAction action,
        string validatorSrcAddress,
        string validatorDstAddress,
        uint256 wTacAmount
    );
    event TacStakingFuseExit(address version, string validator, uint256 amount);
    event TacStakingFuseInstantWithdraw(address version, uint256 amount);
    event TacStakingExecutorCreated(address executor, address plasmaVault, address wTAC, address staking);

    address public immutable VERSION;
    uint256 public immutable MARKET_ID;
    address public immutable W_TAC;
    address public immutable STAKING;

    constructor(uint256 marketId_, address wTAC_, address staking_) {
        if (wTAC_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        if (staking_ == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        VERSION = address(this);
        MARKET_ID = marketId_;
        W_TAC = wTAC_;
        STAKING = staking_;
    }

    /// @notice Creates a new TacStakingExecutor and stores its address in storage
    /// @dev Only callable by alpha role
    function createExecutor() external {
        address existingExecutor = TacStakingStorageLib.getTacStakingExecutor();

        if (existingExecutor != address(0)) {
            revert TacStakingFuseExecutorAlreadyCreated();
        }

        TacStakingExecutor executor = new TacStakingExecutor(address(this), W_TAC, STAKING);

        TacStakingStorageLib.setTacStakingExecutor(address(executor));

        emit TacStakingExecutorCreated(address(executor), address(this), W_TAC, STAKING);
    }

    function enter(TacStakingFuseEnterData memory data_) external {
        if (data_.actions.length == 0) {
            revert TacStakingFuseEmptyArray();
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 balance = IERC20(W_TAC).balanceOf(address(this));
        uint256 remainingBalance = balance;

        /// @dev Transfer wTAC to executor if there's a balance (will be used for DELEGATE actions)
        if (balance > 0) {
            IERC20(W_TAC).safeTransfer(executor, balance);
        }

        for (uint256 i = 0; i < data_.actions.length; i++) {
            TacStakingFuseEnterActionData memory enterAction = data_.actions[i];

            if (enterAction.wTacAmount == 0) {
                continue;
            }

            if (!_validateGrantedSubstrate(enterAction.validatorSrcAddress)) {
                revert TacStakingFuseSubstrateNotGranted(enterAction.validatorSrcAddress);
            }

            if (enterAction.action == TacStakingFuseEnterAction.REDELEGATE) {
                if (bytes(enterAction.validatorDstAddress).length == 0) {
                    revert TacStakingFuseInvalidValidatorDstAddress();
                }

                if (!_validateGrantedSubstrate(enterAction.validatorDstAddress)) {
                    revert TacStakingFuseSubstrateNotGranted(enterAction.validatorDstAddress);
                }

                TacStakingExecutor(executor).redelegate(
                    StakingExecutorTacRedelegateData({
                        validatorSrcAddress: enterAction.validatorSrcAddress,
                        validatorDstAddress: enterAction.validatorDstAddress,
                        wTacAmount: enterAction.wTacAmount
                    })
                );
            } else if (enterAction.action == TacStakingFuseEnterAction.DELEGATE) {
                if (remainingBalance == 0) {
                    continue;
                }

                if (bytes(enterAction.validatorDstAddress).length > 0) {
                    revert TacStakingFuseInvalidValidatorDstAddress();
                }

                uint256 amountToDelegate = enterAction.wTacAmount <= remainingBalance
                    ? enterAction.wTacAmount
                    : remainingBalance;

                TacStakingExecutor(executor).delegate(
                    StakingExecutorTacDelegateData({
                        validatorAddress: enterAction.validatorSrcAddress,
                        wTacAmount: amountToDelegate
                    })
                );

                if (amountToDelegate <= remainingBalance) {
                    remainingBalance -= amountToDelegate;
                } else {
                    remainingBalance = 0;
                }
            } else {
                revert TacStakingFuseInvalidAction();
            }

            emit TacStakingFuseEnter(
                VERSION,
                enterAction.action,
                enterAction.validatorSrcAddress,
                enterAction.validatorDstAddress,
                enterAction.wTacAmount
            );
        }
    }

    function exit(TacStakingFuseExitData memory data_) external {
        if (data_.validators.length == 0) {
            revert TacStakingFuseEmptyArray();
        }

        if (data_.validators.length != data_.wTacAmounts.length) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        for (uint256 i = 0; i < data_.validators.length; i++) {
            if (data_.wTacAmounts[i] == 0) {
                continue;
            }

            if (!_validateGrantedSubstrate(data_.validators[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validators[i]);
            }

            string[] memory validatorAddresses = new string[](1);
            validatorAddresses[0] = data_.validators[i];
            uint256[] memory wTacAmounts = new uint256[](1);
            wTacAmounts[0] = data_.wTacAmounts[i];

            TacStakingExecutor(executor).undelegate(
                StakingExecutorTacUndelegateData({
                    validatorAddress: data_.validators[i],
                    wTacAmount: data_.wTacAmounts[i]
                })
            );

            emit TacStakingFuseExit(VERSION, data_.validators[i], data_.wTacAmounts[i]);
        }
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in wTAC, params[1] - validator hash (bytes32)
    /// @param params_ Array of parameters for withdrawal
    /// @dev Intant withdraw can be done only from TacStakingExecutor
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 amount = uint256(params_[0]);

        if (amount == 0) {
            return;
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 withdrawnAmount = TacStakingExecutor(executor).instantWithdraw(amount);

        emit TacStakingFuseInstantWithdraw(VERSION, withdrawnAmount);
    }

    /// @notice Emergency withdraw all wTAC and native TAC from the Executor
    /// @dev Intant withdraw can be done only from TacStakingExecutor
    function emergencyExit() external {
        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());
        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }
        TacStakingExecutor(executor).emergencyExit();
    }

    /// @notice Converts a validator address string (Bech32) to two bytes32 values
    /// @param validatorAddress_ The validator address string to convert
    /// @return firstSlot_ First bytes32 value containing first part of string
    /// @return secondSlot_ Second bytes32 value containing second part of string
    function convertValidatorAddressToBytes32(
        string memory validatorAddress_
    ) external pure returns (bytes32, bytes32) {
        return TacValidatorAddressConverter.validatorAddressToBytes32(validatorAddress_);
    }

    /// @notice Converts two bytes32 values back to a validator address string (Bech32)
    /// @param firstSlot_ First bytes32 value containing first part of string
    /// @param secondSlot_ Second bytes32 value containing second part of string
    /// @return The reconstructed validator address string (Bech32)
    function convertBytes32ToValidatorAddress(
        bytes32 firstSlot_,
        bytes32 secondSlot_
    ) external pure returns (string memory) {
        return TacValidatorAddressConverter.bytes32ToValidatorAddress(firstSlot_, secondSlot_);
    }

    /// @notice Validates that a validator address is granted as a substrate for the market
    /// @dev Converts validator address string to two bytes32 values and checks if both are granted
    /// @param validatorAddress_ The validator address string to validate
    /// @return True if validator is granted as substrate, false otherwise
    function _validateGrantedSubstrate(string memory validatorAddress_) private view returns (bool) {
        (bytes32 firstSlot, bytes32 secondSlot) = TacValidatorAddressConverter.validatorAddressToBytes32(
            validatorAddress_
        );

        return
            PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, firstSlot) &&
            PlasmaVaultConfigLib.isMarketSubstrateGranted(MARKET_ID, secondSlot);
    }
}
