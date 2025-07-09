// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IFuseCommon} from "../IFuseCommon.sol";
import {IFuseInstantWithdraw} from "../IFuseInstantWithdraw.sol";
import {PlasmaVaultConfigLib} from "../../libraries/PlasmaVaultConfigLib.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {TacStakingExecutor} from "./TacStakingExecutor.sol";
import {TacStakingStorageLib} from "./TacStakingStorageLib.sol";
import {TacValidatorAddressConverter} from "./TacValidatorAddressConverter.sol";

/// @notice Struct to represent the data for entering the fuse - delegate action
/// @dev validatorAddresses - the validator addresses
/// @dev wTacAmounts - the amounts of TAC to delegate
struct TacStakingFuseEnterData {
    string[] validatorAddresses;
    uint256[] wTacAmounts;
}

/// @notice Struct to represent the data for exiting the fuse - undelegate action
/// @dev validatorAddresses - the array of validator addresses
/// @dev wTacAmounts - the array of amounts of wTAC to unstake
struct TacStakingFuseExitData {
    string[] validatorAddresses;
    uint256[] wTacAmounts;
}

/// @notice Struct to represent the data for redelegate action
/// @dev validatorSrcAddresses - the source validator addresses
/// @dev validatorDstAddresses - the destination validator addresses
/// @dev wTacAmounts - the amounts of TAC to redelegate
struct TacStakingFuseRedelegateData {
    string[] validatorSrcAddresses;
    string[] validatorDstAddresses;
    uint256[] wTacAmounts;
}

contract TacStakingFuse is IFuseCommon, IFuseInstantWithdraw {
    using SafeERC20 for IERC20;

    error TacStakingFuseInvalidExecutorAddress();
    error TacStakingFuseSubstrateNotGranted(string validator);
    error TacStakingFuseExecutorAlreadyCreated();
    error TacStakingFuseArrayLengthMismatch();
    error TacStakingFuseEmptyArray();
    error TacStakingFuseInsufficientBalance();

    event TacStakingFuseEnter(address version, string[] validatorAddresses, uint256[] wTacAmounts);
    event TacStakingFuseExit(address version, string[] validatorAddresses, uint256[] wTacAmounts);
    event TacStakingFuseRedelegate(
        address version,
        string[] validatorSrcAddresses,
        string[] validatorDstAddresses,
        uint256[] wTacAmounts
    );
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
    /// @dev Creates a new TacStakingExecutor and stores its address in storage, can be called only once
    function createExecutor() external {
        address existingExecutor = TacStakingStorageLib.getTacStakingExecutor();

        if (existingExecutor != address(0)) {
            revert TacStakingFuseExecutorAlreadyCreated();
        }

        TacStakingExecutor executor = new TacStakingExecutor(address(this), W_TAC, STAKING);

        TacStakingStorageLib.setTacStakingExecutor(address(executor));

        emit TacStakingExecutorCreated(address(executor), address(this), W_TAC, STAKING);
    }

    /// @notice Delegate the balance of the executor to the validators
    /// @dev Only callable by the PlasmaVault contract
    function enter(TacStakingFuseEnterData calldata data_) external {
        if (data_.validatorAddresses.length == 0) {
            revert TacStakingFuseEmptyArray();
        }

        if (data_.validatorAddresses.length != data_.wTacAmounts.length) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 totalWTacAmount = 0;

        for (uint256 i; i < data_.validatorAddresses.length; i++) {
            totalWTacAmount += data_.wTacAmounts[i];
        }

        if (totalWTacAmount == 0) {
            return;
        }

        if (totalWTacAmount > IERC20(W_TAC).balanceOf(address(this))) {
            revert TacStakingFuseInsufficientBalance();
        } else {
            IERC20(W_TAC).safeTransfer(executor, totalWTacAmount);
        }

        for (uint256 i; i < data_.validatorAddresses.length; i++) {
            if (!_validateGrantedSubstrate(data_.validatorAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorAddresses[i]);
            }
        }

        TacStakingExecutor(executor).delegate(data_.validatorAddresses, data_.wTacAmounts);

        emit TacStakingFuseEnter(VERSION, data_.validatorAddresses, data_.wTacAmounts);
    }

    function exit(TacStakingFuseExitData memory data_) external {
        if (data_.validatorAddresses.length == 0) {
            revert TacStakingFuseEmptyArray();
        }

        if (data_.validatorAddresses.length != data_.wTacAmounts.length) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        for (uint256 i = 0; i < data_.validatorAddresses.length; i++) {
            if (!_validateGrantedSubstrate(data_.validatorAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorAddresses[i]);
            }
        }

        TacStakingExecutor(executor).undelegate(data_.validatorAddresses, data_.wTacAmounts);

        emit TacStakingFuseExit(VERSION, data_.validatorAddresses, data_.wTacAmounts);
    }

    function redelegate(TacStakingFuseRedelegateData memory data_) external {
        if (data_.validatorSrcAddresses.length == 0) {
            return;
        }

        if (
            data_.validatorSrcAddresses.length != data_.validatorDstAddresses.length ||
            data_.validatorSrcAddresses.length != data_.wTacAmounts.length
        ) {
            revert TacStakingFuseArrayLengthMismatch();
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        for (uint256 i; i < data_.validatorSrcAddresses.length; i++) {
            if (!_validateGrantedSubstrate(data_.validatorSrcAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorSrcAddresses[i]);
            }

            if (!_validateGrantedSubstrate(data_.validatorDstAddresses[i])) {
                revert TacStakingFuseSubstrateNotGranted(data_.validatorDstAddresses[i]);
            }
        }

        TacStakingExecutor(executor).redelegate(
            data_.validatorSrcAddresses,
            data_.validatorDstAddresses,
            data_.wTacAmounts
        );

        emit TacStakingFuseRedelegate(
            VERSION,
            data_.validatorSrcAddresses,
            data_.validatorDstAddresses,
            data_.wTacAmounts
        );
    }

    /// @notice Handle instant withdrawals
    /// @dev params[0] - amount in wTAC, params[1] - validator hash (bytes32)
    /// @param params_ Array of parameters for withdrawal
    /// @dev Intant withdraw can be done only from TacStakingExecutor
    function instantWithdraw(bytes32[] calldata params_) external override {
        uint256 wTacAmount = uint256(params_[0]);

        if (wTacAmount == 0) {
            return;
        }

        address payable executor = payable(TacStakingStorageLib.getTacStakingExecutor());

        if (executor == address(0)) {
            revert TacStakingFuseInvalidExecutorAddress();
        }

        uint256 withdrawnAmount = TacStakingExecutor(executor).instantWithdraw(wTacAmount);

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
